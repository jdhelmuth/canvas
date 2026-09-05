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


if __name__ == '__main__':
    unittest.main()
