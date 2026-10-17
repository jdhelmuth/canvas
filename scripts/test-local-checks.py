#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest
import tempfile
import contextlib
import io
import json
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('local_checks', Path(__file__).with_name('check-local.py'))
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


class LocalChecksTests(unittest.TestCase):
    def test_platform_selection(self):
        self.assertEqual(checks.scopes_for(['ios/Foo.swift']), ['ios'])
        self.assertEqual(checks.scopes_for(['android/app/build.gradle']), ['android'])
        self.assertEqual(checks.scopes_for(['api/weather.js']), [checks.CONFIG['primary']])
        self.assertEqual(checks.scopes_for(['cloudflare/scheduler-worker/src/index.ts']), [checks.CONFIG['primary']])
        self.assertEqual(checks.scopes_for(['docs/readme.md', '.github/workflows/quality.yml']), [])
        self.assertEqual(checks.scopes_for(['scripts/check-local.py']), ['tools'])

    def test_mixed_changes_keep_native_and_server_checks(self):
        self.assertEqual(set(checks.scopes_for(['ios/Foo.swift', 'android/A.kt', 'server/cronAuth.js'])),
                         {'ios', 'android', checks.CONFIG['primary']})

    def test_release_changes_select_their_helper_tests(self):
        for path in ('release/release-requirements.json', 'scripts/app_store_build_preflight.py',
                     'scripts/test_release_helpers.py', 'scripts/validate_release_requirements.sh',
                     'ci_scripts/ci_pre_xcodebuild.sh', 'scripts/release_config_value.py'):
            with self.subTest(path=path):
                self.assertEqual(checks.scopes_for([path]), ['tools'])
        self.assertEqual(checks.scopes_for(['release/notes.md']), [])

    def test_refuses_unreviewed_or_changed_pr_heads(self):
        good = dict(state='OPEN', isDraft=False, isCrossRepository=False, headRefOid='abc')
        checks.assert_mergeable(good, 'abc')
        for changes in [dict(state='MERGED'), dict(isDraft=True), dict(isCrossRepository=True), dict(headRefOid='def')]:
            with self.assertRaises(RuntimeError):
                checks.assert_mergeable({**good, **changes}, 'abc')

    def test_check_failure_stops_execution(self):
        with self.assertRaisesRegex(RuntimeError, 'nothing was merged'):
            checks.run([sys.executable, '-c', 'raise SystemExit(7)'], '.', 5, checks.tool_environment())

    def test_plan_has_no_check_or_merge_side_effects(self):
        with patch.object(checks, 'capture', return_value='abc'), patch.object(checks, 'run') as run:
            with patch.object(sys, 'argv', ['check-local.py', '--all', '--plan']):
                checks.main()
            run.assert_not_called()


    def test_release_merge_marks_actual_commit_and_keeps_local_checks(self):
        for skip in (False, True):
            with self.subTest(skip=skip), tempfile.TemporaryDirectory() as directory:
                pr = dict(state='OPEN', isDraft=False, isCrossRepository=False,
                          headRefOid='abc', baseRefOid='base', baseRefName='main',
                          title='Ship Canvas [mobile-internal]',
                          body='Verified release.\nLiteral `$()` text stays intact.')
                calls = []
                def capture(*args):
                    if args == ('git', 'rev-parse', 'HEAD'): return 'abc'
                    if args == ('git', 'rev-parse', '--git-path', 'local-checks.json'):
                        return str(Path(directory) / 'checks.json')
                    if args == ('git', 'diff', '--name-only', 'base...HEAD'):
                        return 'scripts/check-local.py'
                    if args[:3] == ('gh', 'pr', 'view'): return json.dumps({'state': 'MERGED'})
                    return ''
                def run(command, *rest):
                    body = None
                    if '--body-file' in command:
                        body = Path(command[command.index('--body-file') + 1]).read_text()
                    calls.append((command, body))
                argv = ['check-local.py', '--merge-pr', '42']
                if skip: argv.append('--skip-cloud-build')
                with patch.object(checks, 'capture', side_effect=capture), \
                     patch.object(checks, 'pr_info', return_value=pr), \
                     patch.object(checks, 'run', side_effect=run), \
                     patch.object(sys, 'argv', argv):
                    checks.main()
                self.assertEqual(calls[0][0], ['python3', 'scripts/test-local-checks.py'])
                command, body = calls[-1]
                self.assertEqual(command[:7], ['gh', 'pr', 'merge', '42', '--squash', '--match-head-commit', 'abc'])
                if skip:
                    self.assertTrue(command[command.index('--subject') + 1].endswith('[ci skip]'))
                    self.assertEqual(body, pr['body'] + '\n\n[ci skip]\n')
                    self.assertFalse(Path(command[command.index('--body-file') + 1]).exists())
                else:
                    self.assertEqual(len(command), 7)
                    self.assertIsNone(body)

    def test_skip_flag_without_merge_is_rejected_before_running_commands(self):
        with patch.object(sys, 'argv', ['check-local.py', '--skip-cloud-build']), \
             patch.object(checks, 'capture') as capture, \
             contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit): checks.main()
            capture.assert_not_called()


class SimulatorSessionTests(unittest.TestCase):
    def setUp(self):
        import simulator_session
        self.module = simulator_session
        self.udid = '11111111-2222-4333-8444-555555555555'
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        temporary_root = patch.object(self.module.tempfile, 'gettempdir', return_value=directory.name)
        temporary_root.start()
        self.addCleanup(temporary_root.stop)
        self.health = {'name': 'Canvas iPad', 'springboard_pid': 123}

    def test_faulty_runtime_is_rejected_before_starting_automation(self):
        devices = {'devices': {'runtime-old': [{'udid': self.udid, 'state': 'Booted'}]}}
        runtimes = {'runtimes': [{'identifier': 'runtime-old', 'isAvailable': True,
                                 'runtimeRoot': '/actual-runtime', 'buildversion': '23F77'}]}
        with patch.object(self.module, 'command', side_effect=[json.dumps(devices), json.dumps(runtimes),
                'UUID: 711229F6-7A68-3A82-A27A-0439C2E1D62A (arm64) binary']) as command:
            with self.assertRaisesRegex(RuntimeError, 'confirmed SpringBoard XCTest'):
                self.module.health_check(self.udid)
            self.assertIn('/actual-runtime/', command.call_args.args[-1])
            self.assertEqual(command.call_count, 3)

    def test_other_runtime_records_binary_identity(self):
        devices = {'devices': {'runtime-new': [{'udid': self.udid}]}}
        runtimes = {'runtimes': [{'identifier': 'runtime-new', 'isAvailable': True,
                                 'runtimeRoot': '/new-runtime', 'buildversion': 'new-build'}]}
        identity = '2AFDDABB-38F9-38F3-B805-AC3B60BDF165'
        with patch.object(self.module, 'command', side_effect=[json.dumps(runtimes),
                'UUID: ' + identity + ' (arm64) binary']):
            result = self.module.automation_runtime(devices, self.udid)
        self.assertEqual(result['automation_uuids'], [identity])
        self.assertEqual(result['build'], 'new-build')

    def test_unidentifiable_automation_runtime_fails_closed(self):
        devices = {'devices': {'runtime': [{'udid': self.udid}]}}
        runtimes = {'runtimes': [{'identifier': 'runtime', 'isAvailable': True,
                                 'runtimeRoot': '/runtime'}]}
        with patch.object(self.module, 'command', side_effect=[json.dumps(runtimes), '']):
            with self.assertRaisesRegex(RuntimeError, 'Cannot identify'):
                self.module.automation_runtime(devices, self.udid)

    def test_healthy_session_records_evidence(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(self.module, 'health_check', return_value=self.health), \
             patch.object(self.module, 'springboard_pid', return_value=123):
            report = Path(directory) / 'evidence.json'
            with self.module.SimulatorSession(self.udid, report, settle_seconds=0).observe():
                pass
            self.assertTrue(json.loads(report.read_text())['healthy'])

    def test_restart_after_successful_test_fails_validation(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(self.module, 'health_check', return_value=self.health), \
             patch.object(self.module, 'springboard_pid', return_value=456):
            report = Path(directory) / 'evidence.json'
            with self.assertRaisesRegex(RuntimeError, 'SpringBoard restarted'):
                with self.module.SimulatorSession(self.udid, report, settle_seconds=0).observe():
                    pass  # xcodebuild returned zero, as it did in the real incident.
            self.assertFalse(json.loads(report.read_text())['healthy'])

    def test_transient_failure_is_not_erased_by_later_recovery(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(self.module, 'health_check', return_value=self.health), \
             patch.object(self.module, 'springboard_pid', side_effect=[RuntimeError('missing PID'), 123]):
            session = self.module.SimulatorSession(self.udid, Path(directory) / 'evidence.json', settle_seconds=0)
            with self.assertRaisesRegex(RuntimeError, 'missing PID'):
                with session.observe():
                    session.sample()

    def test_unhealthy_start_never_runs_test_body(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(self.module, 'health_check', side_effect=RuntimeError('no display')):
            report = Path(directory) / 'evidence.json'
            with self.assertRaisesRegex(RuntimeError, 'no display'):
                with self.module.SimulatorSession(self.udid, report, settle_seconds=0).observe():
                    self.fail('Must not run on an unhealthy simulator')
            self.assertIn('no display', json.loads(report.read_text())['errors'])

    def test_final_display_failure_is_not_a_pass(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(self.module, 'health_check', side_effect=[self.health, RuntimeError('no display')]), \
             patch.object(self.module, 'springboard_pid', return_value=123):
            with self.assertRaisesRegex(RuntimeError, 'no display'):
                with self.module.SimulatorSession(self.udid, Path(directory) / 'evidence.json', settle_seconds=0).observe():
                    pass

    def test_device_lock_refuses_overlapping_checks(self):
        with self.module.device_lock(self.udid):
            with self.assertRaisesRegex(RuntimeError, 'Another Canvas check'):
                with self.module.device_lock(self.udid):
                    self.fail('A second check must not take ownership')

    def test_test_failure_propagates_with_healthy_simulator(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(self.module, 'health_check', return_value=self.health), \
             patch.object(self.module, 'springboard_pid', return_value=123):
            with self.assertRaisesRegex(RuntimeError, 'test failed'):
                with self.module.SimulatorSession(self.udid, Path(directory) / 'evidence.json', settle_seconds=0).observe():
                    raise RuntimeError('test failed')

    def test_native_checks_require_explicit_device_and_clear_old_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'checks.json'
            report.write_text('{"passed":true}')
            def capture(*args):
                if args == ('git', 'rev-parse', '--git-path', 'local-checks.json'): return str(report)
                return 'abc'
            with patch.object(checks, 'capture', side_effect=capture), \
                 patch.dict('os.environ', {}, clear=True), \
                 patch.object(sys, 'argv', ['check-local.py', '--platform', 'ios']), \
                 patch.object(checks, 'run') as run:
                with self.assertRaisesRegex(RuntimeError, 'require --simulator-id'):
                    checks.main()
                run.assert_not_called()
                self.assertFalse(report.exists())


if __name__ == '__main__':
    unittest.main()
