#!/usr/bin/env python3
"""Static guard for the release CI workflow.

GitHub Actions rejects a workflow whose YAML has duplicate mapping keys, and a
malformed `build.yml` fails every push in ~0s with only "workflow file issue".
PyYAML silently keeps the last duplicate, so a normal load would not catch it.
This test loads with a duplicate-key-detecting loader and pins the release
contract: push builds signed release APK + AAB when the keystore secret exists,
and the manual production dispatch keeps the API 36 Play gate.
"""
import re
import shlex
import unittest
from pathlib import Path

import yaml

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/build.yml"


class _DuplicateKeyLoader(yaml.SafeLoader):
    pass


def _no_duplicates(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.constructor.ConstructorError(
                None, None, f"duplicate key {key!r}", key_node.start_mark
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


_DuplicateKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_duplicates
)


def _steps():
    doc = yaml.load(WORKFLOW.read_text(), Loader=_DuplicateKeyLoader)
    return doc["jobs"]["build"]["steps"]


class ReleaseWorkflowTest(unittest.TestCase):
    def test_parses_without_duplicate_keys(self):
        # Raises ConstructorError on a duplicate key -> workflow-file failure.
        steps = _steps()
        self.assertGreater(len(steps), 0)

    def test_push_builds_signed_release_apk_and_aab(self):
        text = WORKFLOW.read_text()
        self.assertIn("Detect release signing availability", text)
        # Release build/upload run whenever the signing secret is present.
        for name in (
            "Build signed release APK + AAB",
            "Upload release APK",
        ):
            self.assertIn(name, text)
        self.assertIn("flutter build appbundle --release", text)
        self.assertIn("release_signing", text)

    def test_production_dispatch_keeps_api36_gate(self):
        text = WORKFLOW.read_text()
        self.assertIn("--mode \"$mode\" --expected-target \"$target\"", text)
        self.assertRegex(text, r"target=36")
        self.assertRegex(text, r"target=28")

    def test_no_production_only_gate_on_push_release(self):
        # The push release path must not require inputs.production_release.
        for step in _steps():
            if step.get("name") == "Build signed release APK + AAB":
                self.assertEqual(step.get("if"), "env.release_signing == 'true'")

    def test_flutter_tests_use_serialized_complete_shards(self):
        steps = _steps()
        test_step = next(step for step in steps if step.get("name") == "Test")
        run = test_step["run"]
        self.assertIn("git ls-files 'test/**_test.dart'", run)
        self.assertIn("for test_file in \"${test_files[@]}\"; do", run)
        self.assertIn("flutter test \"$test_file\"", run)
        self.assertNotIn("|| true", run)
        build = yaml.load(WORKFLOW.read_text(), Loader=_DuplicateKeyLoader)["jobs"]["build"]
        self.assertGreaterEqual(build["timeout-minutes"], 60)

    def test_server_lane_installs_requirements_and_runs_targeted_pytest(self):
        doc = yaml.load(WORKFLOW.read_text(), Loader=_DuplicateKeyLoader)
        server = doc["jobs"]["server-tests"]
        install_run = next(
            step["run"] for step in server["steps"]
            if step.get("name") == "Install server requirements"
        )
        self.assertIn("pip install -r server/account/requirements.txt", install_run)
        server_run = next(
            step["run"] for step in server["steps"]
            if step.get("name") == "Test server account, sync, and collaboration"
        )
        command = shlex.split(server_run.strip())
        self.assertEqual(command[0], "pytest")
        self.assertEqual(
            command[1:],
            ["server/account/tests", "server/sync", "server/collaboration", "server/images", "server/shares"],
        )
        self.assertNotIn("deploy", server.get("name", "").lower())

    def test_server_lane_has_no_production_deployment(self):
        text = WORKFLOW.read_text()
        server_start = text.index("  server-tests:")
        server_text = text[server_start:]
        for forbidden in ("production_release", "release_prepare.py", "flutter build", "upload-artifact"):
            self.assertNotIn(forbidden, server_text)


if __name__ == "__main__":
    unittest.main()
