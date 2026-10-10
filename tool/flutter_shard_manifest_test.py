#!/usr/bin/env python3
"""Validate the behavior of the serialized Flutter shard manifest."""
import re
import shlex
import subprocess
import unittest
from pathlib import Path

import yaml


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
        match = re.search(
            r"git ls-files (?P<quote>'test/\*\*_test\.dart')", run
        )
        if match is None:
            raise AssertionError("workflow does not define a tracked test manifest")
        pattern = shlex.split(match.group("quote"))[0]
        result = subprocess.run(
            ["git", "ls-files", pattern],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.splitlines()

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
        self.assertEqual(manifest, self._expected_manifest())

    def test_serialized_shards_discover_every_tracked_test_file(self):
        run = self._test_step_run()
        manifest = self._manifest_from_workflow(run)
        tracked_tests = self._expected_manifest()
        self.assertGreater(len(tracked_tests), 0)
        self.assertEqual(set(manifest), set(tracked_tests))
        self.assertEqual(manifest, tracked_tests)

    def test_manifest_is_consumed_in_serial_order(self):
        run = self._test_step_run()
        self.assertRegex(run, r"for test_file in \"\$\{test_files\[@\]\}\"; do")
        self.assertRegex(run, r"flutter test \"\$test_file\"")

    def test_manifest_fails_when_no_tracked_tests_are_available(self):
        run = self._test_step_run()
        self.assertIn("if (( ${#test_files[@]} == 0 )); then", run)
        self.assertRegex(run, r"No Flutter tests found\.")


if __name__ == "__main__":
    unittest.main()
