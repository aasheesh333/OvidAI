#!/usr/bin/env python3
"""Static guard for the release CI workflow.

GitHub Actions rejects a workflow whose YAML has duplicate mapping keys, and a
malformed `build.yml` fails every push in ~0s with only "workflow file issue".
PyYAML silently keeps the last duplicate, so a normal load would not catch it.
This test loads with a duplicate-key-detecting loader and pins the release
contract per job: push builds signed release APK + AAB when the keystore secret
exists without waiting for the Flutter test shards, the manual production
dispatch keeps the API 36 Play gate, and every test job stays required.
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


def _workflow():
    return yaml.load(WORKFLOW.read_text(), Loader=_DuplicateKeyLoader)


def _job(name):
    return _workflow()["jobs"][name]


def _steps(job="release"):
    return _job(job)["steps"]


def _step(job, name):
    matches = [step for step in _steps(job) if step.get("name") == name]
    if not matches:
        raise AssertionError(f"job {job!r} has no step {name!r}")
    return matches[0]


def _needs(job):
    needs = _job(job).get("needs", [])
    return [needs] if isinstance(needs, str) else list(needs)


class ReleaseWorkflowTest(unittest.TestCase):
    def test_release_version_advances_past_known_play_build(self):
        pubspec = (Path(__file__).resolve().parents[1] / "pubspec.yaml").read_text()
        self.assertRegex(pubspec, r"(?m)^version: 1\.0\.0\+4$")

    def test_parses_without_duplicate_keys(self):
        # Raises ConstructorError on a duplicate key -> workflow-file failure.
        doc = _workflow()
        for job in ("detect", "release", "analyze", "flutter-tests", "debug-apk", "server-tests"):
            self.assertGreater(len(doc["jobs"][job]["steps"]), 0, job)

    def test_top_level_permissions_and_concurrency_are_kept(self):
        doc = _workflow()
        self.assertEqual(doc["permissions"], {"contents": "read"})
        self.assertEqual(doc["concurrency"]["group"], "android-${{ github.workflow }}-${{ github.ref }}")
        self.assertIs(doc["concurrency"]["cancel-in-progress"], True)
        for name, job in doc["jobs"].items():
            self.assertIn("timeout-minutes", job, name)

    def test_push_builds_signed_release_apk_and_aab(self):
        # Release build/upload run whenever the signing secret is present.
        _step("detect", "Detect release signing availability")
        for name in (
            "Build signed release APK + AAB",
            "Upload release APK",
            "Upload release AAB",
        ):
            _step("release", name)
        self.assertIn("flutter build appbundle --release", _step("release", "Build signed release APK + AAB")["run"])
        self.assertIn("release_signing", WORKFLOW.read_text())

    def test_release_signing_availability_flows_through_job_outputs(self):
        # Job-level `if:` cannot read step env or secrets: the detect job must
        # publish the decision as an output that later jobs consume.
        detect = _job("detect")
        step = _step("detect", "Detect release signing availability")
        self.assertEqual(step["id"], "signing")
        self.assertEqual(detect["outputs"]["release_signing"], "${{ steps.signing.outputs.release_signing }}")
        self.assertEqual(detect["outputs"]["production_profile"], "${{ steps.signing.outputs.production_profile }}")
        self.assertIn('>> "$GITHUB_OUTPUT"', step["run"])
        self.assertEqual(step["env"]["KEYSTORE_B64"], "${{ secrets.ANDROID_KEYSTORE_BASE64 }}")
        release = _job("release")
        self.assertEqual(release["env"]["release_signing"], "${{ needs.detect.outputs.release_signing }}")
        self.assertEqual(release["env"]["production_profile"], "${{ needs.detect.outputs.production_profile }}")
        self.assertIn("needs.detect.outputs.release_signing == 'true'", release["if"])
        for job in ("release", "debug-apk"):
            self.assertNotIn("env.", _job(job)["if"], job)

    def test_release_does_not_wait_for_test_jobs(self):
        self.assertEqual(_needs("release"), ["detect"])
        for slow in ("flutter-tests", "analyze", "debug-apk", "server-tests"):
            self.assertNotIn(slow, _needs("release"))

    def test_debug_apk_is_skipped_when_release_signing_is_available(self):
        debug = _job("debug-apk")
        self.assertEqual(_needs("debug-apk"), ["detect"])
        self.assertIn("needs.detect.outputs.release_signing != 'true'", debug["if"])
        self.assertIn("needs.detect.outputs.production_profile != 'true'", debug["if"])
        gate = _step("debug-apk", "Gate debug APK inventory")["run"]
        # The on-device sandbox is gone: every build targets API 36.
        self.assertIn("--mode debug --expected-target 36", gate)
        _step("debug-apk", "Build debug APK")
        _step("debug-apk", "Upload debug APK")

    def test_every_job_is_required_for_a_green_run(self):
        # No job or step may swallow failures; the analyze job and Flutter shards
        # always run, so the workflow is red whenever a test fails.
        for name, job in _workflow()["jobs"].items():
            self.assertFalse(job.get("continue-on-error", False), name)
            for step in job["steps"]:
                self.assertFalse(step.get("continue-on-error", False), (name, step.get("name")))
        for always in ("analyze", "flutter-tests", "server-tests"):
            self.assertNotIn("if", _job(always), always)

    def test_native_host_tests_and_analysis_run_on_every_event(self):
        names = [(job, step.get("name")) for job, body in _workflow()["jobs"].items()
                 for step in body["steps"] if step.get("name") == "Native host tests"]
        self.assertEqual(names, [("analyze", "Native host tests")])
        self.assertEqual(_step("analyze", "Native host tests")["run"],
                         "./gradlew :app:testDebugUnitTest --no-daemon")
        self.assertEqual(_step("analyze", "Analyze")["run"], "flutter analyze")
        self.assertEqual(_step("analyze", "Test release inventory gates")["run"],
                         "python3 -m unittest discover -s tool -p '*_test.py'")

    def test_embedded_static_rich_content_policy_runs_before_native_tests(self):
        names = [step.get("name") for step in _steps("analyze")]
        policy = _step("analyze", "Test embedded static rich-content policy")
        self.assertEqual(
            policy["run"],
            "node android/app/src/test/js/static_rich_content_policy_test.js",
        )
        self.assertLess(
            names.index("Test embedded static rich-content policy"),
            names.index("Native host tests"),
        )

    def test_release_keeps_secret_handling_and_flag_guard(self):
        release = _job("release")
        self.assertEqual(release["env"]["OVID_ACCOUNT_ENABLED"], "${{ vars.OVID_ACCOUNT_ENABLED || 'false' }}")
        names = [step.get("name") for step in release["steps"]]
        # Production signing is prepared and validated before compilation.
        production_prepare = names.index("Prepare release signing")
        self.assertEqual(release["steps"][production_prepare]["if"], "env.production_profile == 'true'")
        self.assertIn("python3 tool/release_prepare.py", release["steps"][production_prepare]["run"])
        push_prepare = [step for step in release["steps"] if step.get("name") == "Prepare release signing"][1]
        self.assertEqual(push_prepare["if"], "env.release_signing == 'true' && env.production_profile != 'true'")
        build = names.index("Build signed release APK + AAB")
        # The bootstrap packaging step is gone with the on-device sandbox;
        # the remaining secret/flag guards still have to precede compilation.
        for earlier in ("Validate production key before release compilation",
                        "Guard release feature flags"):
            self.assertLess(names.index(earlier), build, earlier)
        self.assertGreater(names.index("Gate release artifacts"), build)
        self.assertLess(names.index("Gate release artifacts"), names.index("Upload release APK"))
        guard = _step("release", "Guard release feature flags")["run"]
        self.assertIn("--dart-define=OVID_RELEASE_FLAGS_CHECK=true", guard)
        self.assertIn('--dart-define=OVID_ACCOUNT_ENABLED="$OVID_ACCOUNT_ENABLED"', guard)
        self.assertEqual(_step("release", "Validate production key before release compilation")["if"],
                         "env.production_profile == 'true'")
        cleanup = _step("release", "Remove injected release credentials")
        self.assertEqual(cleanup["if"],
                         "always() && (env.production_profile == 'true' || env.release_signing == 'true')")
        self.assertEqual(names[-1], "Remove injected release credentials")

    def test_production_dispatch_keeps_api36_gate(self):
        text = _step("release", "Gate release artifacts")["run"]
        self.assertIn("--mode \"$mode\" --expected-target \"$target\"", text)
        self.assertRegex(text, r"target=36")
        # EM-001 / CT-017: the target-28 sideload profile existed only for the
        # removed on-device sandbox. Both profiles now target API 36.
        self.assertNotRegex(text, r"target=28")
        self.assertRegex(text, r"target=36; profile=play")
        self.assertRegex(text, r"target=36; profile=sideload")
        self.assertEqual(WORKFLOW.read_text().count('--profile "$profile"'), 2)

    def test_no_build_targets_the_legacy_sdk(self):
        text = WORKFLOW.read_text()
        self.assertNotIn("--expected-target 28", text)
        self.assertNotRegex(text, r"target=28")

    def test_release_uploads_dart_symbols_and_r8_mapping(self):
        # CT-021: release crashes must be symbolicatable. Both artifacts are
        # uploaded for every signed release build, before credential cleanup.
        names = [step.get("name") for step in _steps("release")]
        symbols = _step("release", "Upload Dart symbols (split-debug-info)")
        self.assertEqual(symbols["if"], "env.release_signing == 'true' || env.production_profile == 'true'")
        self.assertEqual(symbols["with"]["path"], "build/symbols/")
        self.assertEqual(symbols["with"]["if-no-files-found"], "error")
        mapping = _step("release", "Upload R8 mapping")
        self.assertEqual(mapping["if"], "env.release_signing == 'true' || env.production_profile == 'true'")
        self.assertIn("build/app/outputs/mapping/release/", mapping["with"]["path"])
        self.assertEqual(mapping["with"]["if-no-files-found"], "error")
        build = names.index("Build signed release APK + AAB")
        for name in ("Upload Dart symbols (split-debug-info)", "Upload R8 mapping"):
            self.assertGreater(names.index(name), build, name)
            self.assertLess(names.index(name), names.index("Remove injected release credentials"), name)
            self.assertRegex(_step("release", name)["uses"], r"@[0-9a-f]{40}$")

    def test_push_builds_signed_full_release(self):
        # Every push builds a signed APK + AAB when the keystore secret exists.
        # The release branch gets the production Play profile; other branches
        # retain a signed sideload candidate.
        detect = _step("detect", "Detect release signing availability")
        self.assertIn('"${{ github.event_name }}" = "push"', detect["run"])
        build = _step("release", "Build signed release APK + AAB")
        self.assertIn('if [ "$production_profile" = "true" ]; then play_define=', build["run"])

    def test_release_branch_push_selects_production_play_profile(self):
        detect = _step("detect", "Detect release signing availability")["run"]
        self.assertIn('refs/heads/feat/ovid-si-rebuild', detect)
        self.assertIn('production_profile=true', detect)
        self.assertIn('if [ "$production_profile" = "true" ]; then\n  release_signing=true', detect)
        release = _job("release")
        self.assertIn("needs.detect.outputs.production_profile == 'true'", release["if"])
        build = _step("release", "Build signed release APK + AAB")["run"]
        self.assertIn('--dart-define=OVID_PLAY_BUILD=true', build)
        self.assertIn('--dart-define=OVID_PRODUCTION=true', build)
        self.assertIn('--dart-define=OVID_APPCHECK=false', build)
        for name in (
            "Guard release feature flags",
            "Build signed release APK + AAB",
            "Gate release artifacts",
            "Upload release APK",
            "Upload release AAB",
            "Upload Dart symbols (split-debug-info)",
            "Upload R8 mapping",
        ):
            self.assertIn("env.production_profile == 'true'", _step("release", name)["if"], name)
        gate = _step("release", "Gate release artifacts")["run"]
        self.assertIn('if [ "$production_profile" = "true" ]; then mode=production; target=36; profile=play;', gate)
        self.assertIn('else mode=release; target=36; profile=sideload;', gate)

    def test_other_branch_push_remains_sideload(self):
        detect = _step("detect", "Detect release signing availability")["run"]
        self.assertIn('refs/heads/feat/ovid-si-rebuild', detect)
        self.assertNotIn('refs/heads/feat/ovid-cloud', detect.split('production_profile=true', 1)[1])

    def test_release_branch_push_requires_production_signing_inputs(self):
        release = _job("release")
        prepare = _step("release", "Prepare release signing")
        self.assertEqual(prepare["if"], "env.production_profile == 'true'")
        for secret in (
            "${{ secrets.ANDROID_KEYSTORE_BASE64 }}",
            "${{ secrets.ANDROID_KEYSTORE_PASSWORD }}",
            "${{ secrets.ANDROID_KEY_ALIAS }}",
            "${{ secrets.ANDROID_KEY_PASSWORD }}",
            "${{ secrets.GOOGLE_SERVICES_JSON }}",
        ):
            self.assertIn(secret, prepare["env"].values())
        self.assertIn("python3 tool/release_prepare.py", prepare["run"])
        self.assertIn("needs.detect.outputs.production_profile == 'true'", release["if"])

    def test_no_production_only_gate_on_push_release(self):
        # The push release path must not require inputs.production_release.
        self.assertEqual(_step("release", "Build signed release APK + AAB").get("if"),
                         "env.release_signing == 'true' || env.production_profile == 'true'")
        self.assertNotEqual(_job("release")["if"].strip(), "inputs.production_release == true")

    def test_flutter_tests_use_bounded_complete_batches(self):
        test_step = _step("flutter-tests", "Test")
        run = test_step["run"]
        self.assertIn("python3 tool/run_flutter_suite.py", run)
        self.assertIn('--flutter "$(command -v flutter)"', run)
        self.assertIn("--batch-size 20 --batch-timeout 600", run)
        self.assertIn("--shard-index ${{ matrix.shard }} --shard-count 3", run)
        self.assertNotIn('flutter test "$test_file"', run)
        self.assertNotIn("|| true", run)
        self.assertEqual(_step("flutter-tests", "Test with bounded Flutter suite runner")["run"], run)
        shards = _job("flutter-tests")
        self.assertGreaterEqual(shards["timeout-minutes"], 30)
        self.assertIs(shards["strategy"]["fail-fast"], False)
        evidence = _step("flutter-tests", "Upload bounded Flutter suite evidence")
        self.assertEqual(evidence["if"], "always()")
        self.assertIn("${{ matrix.shard }}", evidence["with"]["name"])

    def test_gradle_and_flutter_caches_are_enabled(self):
        for job in ("release", "analyze", "debug-apk"):
            java = _step(job, "Setup Java")
            self.assertEqual(java["with"]["cache"], "gradle", job)
            self.assertIn("gradle-wrapper.properties", java["with"]["cache-dependency-path"])
        for job in ("release", "analyze", "flutter-tests", "debug-apk"):
            flutter = _step(job, "Setup Flutter")
            self.assertIs(flutter["with"]["cache"], True, job)
            self.assertEqual(flutter["with"]["flutter-version"], "3.47.4", job)
            self.assertIn("pubspec.lock", flutter["with"]["pub-cache-key"])

    def test_actions_are_pinned_to_commit_shas(self):
        for name, job in _workflow()["jobs"].items():
            for step in job["steps"]:
                if "uses" in step:
                    self.assertRegex(step["uses"], r"@[0-9a-f]{40}$", (name, step.get("name")))
    def test_server_lane_installs_requirements_and_runs_targeted_pytest(self):
        server = _job("server-tests")
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
            [
                "server/account/tests",
                "server/sync",
                "server/collaboration",
                "server/images",
                "server/shares",
                "server/billing",
                "server/reports",
            ],
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
