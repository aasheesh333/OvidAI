#!/usr/bin/env python3
"""Exercise the suite runner with a real subprocess speaking Flutter JSON."""
import fcntl
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


RUNNER = Path(__file__).with_name("run_flutter_suite.py")
FAKE = r'''#!/usr/bin/env python3
import fcntl, json, pathlib, subprocess, sys, time
root = pathlib.Path.cwd()
args = sys.argv[1:]
assert args[:4] == ['test', '--no-pub', '--concurrency=2', '--machine'], args
with (root / 'sdk.lock').open('a') as lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        raise AssertionError('runner did not hold SDK lock')
files = args[4:]
with (root / 'calls.jsonl').open('a') as out:
    out.write(json.dumps(files) + '\n')
def emit(kind, **kw):
    print(json.dumps(dict(type=kind, **kw)), flush=True)
failed = False
for i, path in enumerate(files):
    name = pathlib.Path(path).name
    emit('suite', suite=dict(id=i, path=str(root / path)))
    emit('testStart', test=dict(id=i*10, suiteID=i, name='loading '+path))
    emit('testDone', testID=i*10, result='success', hidden=True, skipped=False)
    emit('group', group=dict(id=i*10+1, suiteID=i, parentID=None, testCount=1))
    emit('testStart', test=dict(id=i*10+2, suiteID=i, name='actual test'))
    if name == 'hang_test.dart':
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
        (root / 'child.pid').write_text(str(child.pid))
        time.sleep(60)
    if name == 'truncated_test.dart':
        sys.exit(0)
    bad = name == 'fail_test.dart' or (name == 'flaky_test.dart' and len(files)>1)
    if bad:
        failed = True
        emit('error', testID=i*10+2, error='deliberate failure', stackTrace='fixture')
    emit('testDone', testID=i*10+2, result='failure' if bad else 'success', hidden=False, skipped=False)
emit('done', success=not failed)
sys.exit(1 if failed else 0)
'''


class FlutterSuiteRunnerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="flutter-runner-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "test").mkdir()
        self.fake = self.root / "flutter"
        self.fake.write_text(FAKE)
        self.fake.chmod(0o755)

    def files(self, *names):
        for name in names:
            path = self.root / "test" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("// untracked test fixture\n")

    def command(self, *extra):
        return [sys.executable, str(RUNNER), "--root", str(self.root),
                "--flutter", str(self.fake), "--output", str(self.root / "logs"),
                "--lock", str(self.root / "sdk.lock"), "--batch-size", "2",
                "--batch-timeout", "0.5", "--lock-timeout", "2", *extra]

    def run_suite(self, *extra):
        result = subprocess.run(self.command(*extra), capture_output=True, text=True, timeout=15)
        self.assertTrue((self.root / "logs/summary.json").exists(), result.stderr)
        return result, json.loads((self.root / "logs/summary.json").read_text())

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

    def test_filesystem_discovery_includes_untracked_nested_files_in_sorted_batches(self):
        self.files("z_test.dart", "nested/b_test.dart", "a_test.dart", "helper.dart")
        result, summary = self.run_suite()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [["test/a_test.dart", "test/nested/b_test.dart"], ["test/z_test.dart"]])
        self.assertEqual(summary["counts"]["passed"], 3)
        self.assertEqual(summary["counts"]["inventory"], 3)
        self.assertTrue((self.root / "logs/tree-start.json").exists())
        self.assertTrue((self.root / "logs/tree-end.json").exists())

    def test_failure_retains_evidence_retries_only_failed_file_and_continues(self):
        self.files("a_test.dart", "fail_test.dart", "z_test.dart")
        result, summary = self.run_suite()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [["test/a_test.dart", "test/fail_test.dart"], ["test/fail_test.dart"], ["test/z_test.dart"]])
        self.assertEqual(summary["passed_files"], ["test/a_test.dart", "test/z_test.dart"])
        self.assertEqual(summary["failed_files"], ["test/fail_test.dart"])
        self.assertIn("deliberate failure", (self.root / "logs/batch-0001.log").read_text())
        self.assertTrue(summary["attempts"][0]["errors"])

    def test_successful_retry_does_not_erase_observed_failure(self):
        self.files("a_test.dart", "flaky_test.dart")
        result, summary = self.run_suite()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(summary["recovered_files"], ["test/flaky_test.dart"])
        self.assertEqual(summary["failed_files"], ["test/flaky_test.dart"])

    def test_timeout_kills_children_preserves_completed_files_and_continues(self):
        self.files("a_test.dart", "hang_test.dart", "z_test.dart")
        started = time.monotonic()
        result, summary = self.run_suite()
        self.assertLess(time.monotonic() - started, 8)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(summary["passed_files"], ["test/a_test.dart", "test/z_test.dart"])
        self.assertEqual(summary["failed_files"], ["test/hang_test.dart"])
        self.assertTrue(summary["attempts"][0]["timed_out"])
        pid = int((self.root / "child.pid").read_text())
        proc = Path(f"/proc/{pid}/stat")
        self.assertTrue(not proc.exists() or proc.read_text().split()[2] == "Z", "orphan child still running")

    def test_zero_exit_without_completion_is_not_green(self):
        self.files("truncated_test.dart")
        result, summary = self.run_suite()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(summary["counts"]["passed"], 0)

    def test_files_not_reached_before_hang_get_their_first_execution(self):
        self.files("hang_test.dart", "later_test.dart", "z_test.dart")
        result, summary = self.run_suite()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [["test/hang_test.dart", "test/later_test.dart"],
                                       ["test/hang_test.dart"], ["test/later_test.dart"],
                                       ["test/z_test.dart"]])
        self.assertEqual(summary["passed_files"], ["test/later_test.dart", "test/z_test.dart"])
        self.assertEqual(summary["unverified_files"], [])

    def test_lock_timeout_reports_unverified_files_and_does_not_launch_sdk(self):
        self.files("a_test.dart")
        with (self.root / "sdk.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result, summary = self.run_suite("--lock-timeout", "0.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "calls.jsonl").exists())
        self.assertEqual(summary["unverified_files"], ["test/a_test.dart"])

    def test_existing_evidence_is_not_overwritten(self):
        self.files("a_test.dart")
        self.run_suite()
        original = (self.root / "logs/summary.json").read_bytes()
        result = subprocess.run(self.command(), capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "logs/summary.json").read_bytes(), original)

    def test_termination_reaps_active_sdk_children_and_finalizes_failure_report(self):
        self.files("hang_test.dart")
        process = subprocess.Popen(self.command("--batch-timeout", "5"),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        child = None
        try:
            deadline = time.monotonic() + 5
            while not (self.root / "child.pid").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue((self.root / "child.pid").exists())
            child = int((self.root / "child.pid").read_text())
            process.send_signal(signal.SIGTERM)
            process.communicate(timeout=8)
            self.assertNotEqual(process.returncode, 0)
            summary = json.loads((self.root / "logs/summary.json").read_text())
            self.assertIsNotNone(summary["finished_at"])
            self.assertTrue(summary["errors"])
            proc = Path(f"/proc/{child}/stat")
            self.assertTrue(not proc.exists() or proc.read_text().split()[2] == "Z")
        finally:
            if child:
                # Clean up the intentionally failing red-phase subprocess too.
                try:
                    os.killpg(os.getpgid(child), signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if process.poll() is None:
                process.kill()
            process.communicate()

    def test_empty_inventory_is_not_green(self):
        result, summary = self.run_suite()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(summary["counts"]["inventory"], 0)
        self.assertTrue(summary["errors"])

    def test_lock_wait_does_not_spend_batch_execution_timeout(self):
        self.files("a_test.dart")
        with (self.root / "sdk.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            process = subprocess.Popen(self.command(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                time.sleep(0.8)
                self.assertIsNone(process.poll())
                self.assertFalse((self.root / "calls.jsonl").exists())
                fcntl.flock(lock, fcntl.LOCK_UN)
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, stdout + stderr)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    unittest.main()
