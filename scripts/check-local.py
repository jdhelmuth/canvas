#!/usr/bin/env python3
"""Run the relevant checks locally; optionally merge a verified, unchanged PR."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
CONFIG = json.loads((ROOT / 'scripts/local-checks.json').read_text())


def capture(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def scopes_for(paths):
    scopes = set()
    for path in paths:
        if path.startswith(('ios/', 'Canvas/', 'CanvasTests/', 'CanvasUITests/', 'Canvas.xcodeproj/')):
            scopes.add('ios')
        elif path.startswith('android/'):
            scopes.add('android')
        elif path in ('scripts/check-local.py', 'scripts/test-local-checks.py', 'scripts/local-checks.json'):
            scopes.add('tools')
        elif path.startswith(('docs/', '.github/', 'release/', 'app-store-submission/')) or path.endswith('.md'):
            continue
        else:
            scopes.add(CONFIG['primary'])
    return sorted(scopes)


def assert_mergeable(pr, head):
    if pr['state'] != 'OPEN' or pr['isDraft'] or pr['isCrossRepository']:
        raise RuntimeError('Only an open, non-draft PR from this repository can be merged here.')
    if pr['headRefOid'] != head:
        raise RuntimeError('Check out the exact PR head before using --merge-pr.')


def pr_info(number):
    return json.loads(capture('gh', 'pr', 'view', str(number), '--json',
        'state,isDraft,isCrossRepository,headRefOid,baseRefOid,baseRefName,title,body'))


def run(command, directory, timeout, env):
    print('\nChecking: ' + ' '.join(command), flush=True)
    proc = subprocess.Popen(command, cwd=ROOT / directory, env=env, start_new_session=True)
    try:
        code = proc.wait(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
        raise RuntimeError('Local check stopped or exceeded its time limit.')
    if code:
        raise RuntimeError(f'Local check failed with exit code {code}; nothing was merged.')


def tool_environment():
    env = os.environ.copy()
    # This Mac has Node 22 installed alongside an older default Node.
    # Use an existing installation only; never install or upgrade tools here.
    for directory in ('/opt/homebrew/opt/node@22/bin', '/usr/local/opt/node@22/bin'):
        if Path(directory, 'node').exists():
            env['PATH'] = directory + os.pathsep + env.get('PATH', '')
            break
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    env['TZ'] = 'America/New_York'
    return env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--base', help='Compare with this fetched base ref (default: origin/main).')
    group.add_argument('--all', action='store_true', help='Run all platforms; requires native toolchains.')
    group.add_argument('--platform', choices=list(CONFIG['commands']), help='Run one platform explicitly.')
    group.add_argument('--merge-pr', type=int, help='Check this PR head locally, then squash-merge that exact head.')
    parser.add_argument('--plan', action='store_true', help='Print selected checks without running or merging.')
    parser.add_argument('--skip-cloud-build', action='store_true',
                        help='Merge without starting another Xcode Cloud build; keep local checks.')
    args = parser.parse_args()
    if args.skip_cloud_build and not args.merge_pr:
        parser.error('--skip-cloud-build requires --merge-pr.')
    head = capture('git', 'rev-parse', 'HEAD')
    pr = None
    if args.merge_pr:
        if capture('git', 'status', '--porcelain'):
            raise RuntimeError('--merge-pr requires a clean working tree.')
        pr = pr_info(args.merge_pr)
        assert_mergeable(pr, head)
        capture('git', 'fetch', 'origin', pr['baseRefName'])
        base = pr['baseRefOid']
    else:
        base = args.base or 'origin/main'
    if args.all:
        scopes = sorted(CONFIG['commands'])
    elif args.platform:
        scopes = [args.platform]
    else:
        paths = set(capture('git', 'diff', '--name-only', f'{base}...HEAD').splitlines())
        paths.update(capture('git', 'diff', '--name-only', 'HEAD').splitlines())
        paths.update(capture('git', 'ls-files', '--others', '--exclude-standard').splitlines())
        scopes = scopes_for(paths)
    print('Selected checks: ' + (', '.join(scopes) or 'none (documentation/workflow-only changes)'), flush=True)
    if args.plan:
        for scope in scopes:
            for step in CONFIG['commands'][scope]:
                print(scope + ': ' + ' '.join(step['command']))
        return
    env = tool_environment()
    started = time.time()
    for scope in scopes:
        scope_env = env.copy()
        if scope == 'android' and sys.platform == 'darwin':
            scope_env['JAVA_HOME'] = capture('/usr/libexec/java_home', '-v', str(CONFIG['java']))
            scope_env['ANDROID_HOME'] = env.get('ANDROID_HOME', str(Path.home() / 'Library/Android/sdk'))
        for step in CONFIG['commands'][scope]:
            command = list(step['command'])
            if '{simulator}' in command:
                devices = json.loads(capture('xcrun', 'simctl', 'list', 'devices', 'available', '-j'))
                phones = [d for values in devices['devices'].values() for d in values if 'iPad' in d['name']]
                if not phones:
                    raise RuntimeError('An available iPhone simulator is required for native tests.')
                phone = next((d for d in phones if d['state'] == 'Booted'), phones[0])
                command[command.index('{simulator}')] = 'platform=iOS Simulator,id=' + phone['udid']
            run(command, step.get('cwd', '.'), step.get('timeout', 900), scope_env)
    if capture('git', 'rev-parse', 'HEAD') != head:
        raise RuntimeError('HEAD changed during validation; rerun the checks.')
    report = {'commit': head, 'base': base, 'scopes': scopes, 'passed': True,
              'completed_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
              'duration_seconds': round(time.time() - started)}
    report_path = Path(capture('git', 'rev-parse', '--git-path', 'local-checks.json'))
    if not report_path.is_absolute():
        report_path = ROOT / report_path
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    if args.merge_pr:
        if capture('git', 'status', '--porcelain'):
            raise RuntimeError('Working files changed during validation; commit and rerun before merging.')
        current = pr_info(args.merge_pr)
        assert_mergeable(current, head)
        if current['baseRefOid'] != pr['baseRefOid']:
            raise RuntimeError('The PR base moved during validation; update your branch and rerun.')
        command = ['gh', 'pr', 'merge', str(args.merge_pr), '--squash', '--match-head-commit', head]
        if args.skip_cloud_build:
            # Mark the actual squash commit, not just a feature-branch commit:
            # Xcode Cloud evaluates the new main commit when the PR merges.
            subject = current['title'].rstrip()
            if not subject.endswith('[ci skip]'):
                subject += ' [ci skip]'
            body = current.get('body') or ''
            with tempfile.NamedTemporaryFile(mode='w', suffix='.md') as merge_body:
                merge_body.write(body.rstrip() + '\n\n[ci skip]\n')
                merge_body.flush()
                run(command + ['--subject', subject, '--body-file', merge_body.name], '.', 120, env)
        else:
            run(command, '.', 120, env)
        state = json.loads(capture('gh', 'pr', 'view', str(args.merge_pr), '--json', 'state'))
        if state['state'] != 'MERGED':
            raise RuntimeError('Merge was not confirmed by GitHub.')
        print('Verified PR merged.')
    else:
        print('Local checks passed. No merge or deployment was performed.')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, FileNotFoundError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
