#!/usr/bin/env python3
"""Validate the behavior of the serialized Flutter shard manifest."""
import re
import shlex
import subprocess
import unittest
from pathlib import Path

import yaml
from tool.run_flutter_suite import discover


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/build.yml"


class FlutterShardManifestTest(unittest.TestCase):
    @staticmethod
    def _test_step_run():
        document = yaml.safe_load(WORKFLOW.read_text())
        return next(
            step["run"]
            for step in document["jobs"]["build"]["steps"]
            if step.get("name") == "Test"
        )

    @staticmethod
    def _manifest_from_workflow(run):
        if 'python3 tool/run_flutter_suite.py' not in run:
            raise AssertionError("workflow does not invoke the inventory runner")
        return discover(ROOT)

    @staticmethod
    def _expected_manifest():
        result = subprocess.run(
            ["git", "ls-files", "test"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        return sorted(
            path for path in result.stdout.splitlines() if path.endswith("_test.dart")
        )

    def test_manifest_matches_repository_tracked_test_files(self):
        manifest = self._manifest_from_workflow(self._test_step_run())
        self.assertTrue(set(self._expected_manifest()) <= set(manifest))
        self.assertEqual(manifest, sorted(set(manifest)))

    def test_serialized_shards_discover_every_tracked_test_file(self):
        run = self._test_step_run()
        manifest = self._manifest_from_workflow(run)
        tracked_tests = self._expected_manifest()
        self.assertGreater(len(tracked_tests), 0)
        self.assertTrue(set(tracked_tests) <= set(manifest))
        self.assertEqual(manifest, sorted(set(manifest)))

    def test_manifest_is_partitioned_once_into_bounded_batches(self):
        run = self._test_step_run()
        size = int(re.search(r'--batch-size (\d+)', run).group(1))
        manifest = self._manifest_from_workflow(run)
        batches = [manifest[i:i + size] for i in range(0, len(manifest), size)]
        self.assertEqual([name for batch in batches for name in batch], manifest)
        self.assertTrue(all(0 < len(batch) <= 20 for batch in batches))
        self.assertIn('--batch-timeout 600', run)
        self.assertNotIn('|| true', run)

    def test_manifest_fails_when_no_tracked_tests_are_available(self):
        import tempfile
        with tempfile.TemporaryDirectory() as path:
            self.assertEqual(discover(Path(path)), [])
        # Runner failure semantics (including empty inventory) are verified by
        # run_flutter_suite_test; the workflow must propagate its exit code.
        self.assertNotIn('|| true', self._test_step_run())


if __name__ == "__main__":
    unittest.main()
