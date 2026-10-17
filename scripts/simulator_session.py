"""Observe one explicitly selected simulator; never boot, reset, or recover it."""
import contextlib
import fcntl
import json
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
import uuid

# Confirmed in the October 10 and October 17 SpringBoard reports. Checking the
# actual runtime binary avoids confusing Xcode's newer framework with the one
# SpringBoard loads. A different UUID is not a guarantee of runtime health;
# keep the PID/display monitor and teardown observation below.
FAULTY_AUTOMATION_UUIDS = {'711229F6-7A68-3A82-A27A-0439C2E1D62A'}


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=15)
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout).strip())
    return result.stdout


def springboard_pid(udid):
    output = command('xcrun', 'simctl', 'spawn', udid, 'launchctl', 'list', 'com.apple.SpringBoard')
    match = re.search(r'"PID"\s*=\s*(\d+)', output)
    if not match or int(match[1]) <= 0:
        raise RuntimeError('SpringBoard is not running on ' + udid)
    return int(match[1])


def automation_runtime(devices, udid):
    identifiers = [identifier for identifier, group in devices['devices'].items()
                   if any(device['udid'] == udid for device in group)]
    if len(identifiers) != 1:
        raise RuntimeError('Cannot identify the selected simulator runtime.')
    runtimes = json.loads(command('xcrun', 'simctl', 'list', 'runtimes', '-j'))['runtimes']
    matches = [runtime for runtime in runtimes if runtime['identifier'] == identifiers[0]
               and runtime.get('isAvailable')]
    if len(matches) != 1 or not matches[0].get('runtimeRoot'):
        raise RuntimeError('Cannot inspect the selected simulator runtime.')
    runtime = matches[0]
    binary = Path(runtime['runtimeRoot']) / 'Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework/XCTAutomationSupport'
    output = command('xcrun', 'dwarfdump', '--uuid', str(binary))
    identities = re.findall(r'UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)', output)
    if not identities:
        raise RuntimeError('Cannot identify the runtime XCTAutomationSupport binary.')
    if any(identity.upper() in FAULTY_AUTOMATION_UUIDS for identity, _ in identities):
        raise RuntimeError('This simulator runtime contains the confirmed SpringBoard XCTest '
                           'teardown defect. Upgrade this device to a validated runtime before '
                           'running tests; restarting it does not repair the framework. '
                           'See docs/springboard-investigation.md.')
    return {'identifier': runtime['identifier'], 'build': runtime.get('buildversion'),
            'automation_uuids': [identity.upper() for identity, _ in identities]}


def health_check(udid):
    devices = json.loads(command('xcrun', 'simctl', 'list', 'devices', 'available', '-j'))
    device = next((d for group in devices['devices'].values() for d in group if d['udid'] == udid), None)
    if not device or device['state'] != 'Booted':
        raise RuntimeError('The explicitly selected Canvas simulator must already be booted and healthy.')
    runtime = automation_runtime(devices, udid)
    initial_pid = springboard_pid(udid)
    # simctl refuses the screenshot if the display is unavailable. Validate its
    # PNG signature and nonzero dimensions as well, without retaining UI pixels.
    with tempfile.TemporaryDirectory(prefix='canvas-display-') as directory:
        path = Path(directory) / 'frame.png'
        command('xcrun', 'simctl', 'io', udid, 'screenshot', '--type=png', '--display=internal', str(path))
        data = path.read_bytes()
        if (len(data) < 33 or data[:8] != b'\x89PNG\r\n\x1a\n' or data[12:16] != b'IHDR'
                or int.from_bytes(data[16:20], 'big') == 0 or int.from_bytes(data[20:24], 'big') == 0):
            raise RuntimeError('Simulator did not produce a valid display frame.')
    if springboard_pid(udid) != initial_pid:
        raise RuntimeError('SpringBoard restarted during display check.')
    return {'name': device['name'], 'springboard_pid': initial_pid, 'runtime': runtime}


@contextlib.contextmanager
def device_lock(udid):
    # Shared across checkouts, held through test-session teardown. Deliberately
    # no automatic recovery: another operation must not conceal a failed run.
    path = Path(tempfile.gettempdir()) / ('canvas-simulator-' + udid + '.lock')
    with path.open('a') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError('Another Canvas check owns simulator ' + udid) from exc
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


class SimulatorSession:
    def __init__(self, udid, report_path, settle_seconds=10, interval=1):
        self.udid = str(uuid.UUID(udid)).upper()
        self.report_path = Path(report_path)
        self.settle_seconds, self.interval = settle_seconds, interval
        self.stop = threading.Event()
        self.report = {'udid': self.udid, 'healthy': False, 'samples': 0, 'errors': []}

    def sample(self):
        try:
            pid = springboard_pid(self.udid)
            self.report['samples'] += 1
            if pid != self.report['before']['springboard_pid']:
                raise RuntimeError(f"SpringBoard restarted ({self.report['before']['springboard_pid']} -> {pid})")
        except Exception as exc:
            message = str(exc)
            if message not in self.report['errors']:
                self.report['errors'].append(message)

    def monitor(self):
        while not self.stop.wait(self.interval):
            self.sample()

    @contextlib.contextmanager
    def observe(self):
        with device_lock(self.udid):
            worker = None
            try:
                try:
                    self.report['before'] = health_check(self.udid)
                except Exception as exc:
                    self.report['errors'].append(str(exc))
                    raise
                self.report['started_at'] = time.time()
                worker = threading.Thread(target=self.monitor, daemon=True)
                worker.start()
                yield self.report
            finally:
                if worker:
                    # XCTest may return success before SpringBoard finishes
                    # invalidating its automation session. Observe that tail.
                    self.stop.wait(self.settle_seconds)
                    self.stop.set()
                    worker.join(timeout=20)
                    if worker.is_alive():
                        self.report['errors'].append('SpringBoard monitor did not finish.')
                    else:
                        self.sample()
                    try:
                        self.report['after'] = health_check(self.udid)
                        if self.report['after']['springboard_pid'] != self.report['before']['springboard_pid']:
                            self.report['errors'].append('SpringBoard changed during final display check.')
                    except Exception as exc:
                        self.report['errors'].append(str(exc))
                    self.report['healthy'] = not self.report['errors']
                self.report['completed_at'] = time.time()
                self.report_path.write_text(json.dumps(self.report, indent=2) + '\n')
                if self.report['errors']:
                    raise RuntimeError('Simulator validation failed: ' + '; '.join(self.report['errors'])
                                       + '. Evidence: ' + str(self.report_path))
