import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/commands.dart';
import 'package:ovid_ai/core/plan_mode.dart';
import 'package:ovid_ai/core/presets.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';

/// G1–G7: closing the gaps the plan-mode gap analysis
/// (`docs/PLAN_MODE_GAP_ANALYSIS.md` §5) left open.
///
///  * **G1** — `AgentRun.planMode` was write-only (5 writers, 0 readers). A
///    second copy of the policy that nothing consults is exactly how the two
///    used to disagree, so it is gone.
///  * **G2** — no turn-boundary queue: a plan-mode change made mid-turn re-gated
///    the turn already in flight. Now it lands at the boundary (dsh's `queued`).
///  * **G3** — planning could not use a different model or temperature.
///  * **G4** — plan mode was a dispatch gate only, so the model was still
///    OFFERED every tool it would be refused.
///  * **G5** — the plan policy was not user-authorable.
///  * **G6** — `/plan` could silently strand staged attachments.
///  * **G7** — the policy had no single definition.
///
/// ## Audit pass (2026-09-28) — hermetic + falsifiable
///
///  * **Hermetic.** `setUp` pins `SessionLedger.rootOverrideForTest` to a
///    scratch dir under the system temp root, so no test here can write into
///    the repo or hit the path_provider channel. `tearDown` releases the run
///    bucket, the run-session override, the staged attachments and the custom
///    presets — every one of them process-global, and every one of them reused
///    across tests because all tests share the session id `plan-policy`. A run
///    bucket left `busy` would silently QUEUE the next test's transition.
///  * **No mutating tool is ever dispatched.** A gate that wrongly lets one
///    through would really write into the repo, so "allowed" is asserted
///    through the roster projection (`roster()`) and the policy module. The
///    probes are `device_tap` (a correctly-open gate falls through to the
///    Control-mode refusal — nothing is tapped), `git_log` (refused by the gate,
///    which returns before the handler) and `commit` (allowed only by the
///    preset's own policy, and its handler returns "no pending changes" before
///    it can push).
///  * **Falsifiable.** G7's briefing check greps the three halves of the real
///    splice — the `<<<PLAN_MODE_SECTION>>>` token, its use in the template,
///    and the `buildSys()` swap. It used to assert a
///    `${planMode ? PlanModePolicy.promptSection :` literal, which appears
///    NOWHERE in `agent_service.dart` (the source writes that ternary as plain
///    Dart), so it could never pass. G4 asserts the policy before the roster so
///    the "not offered" loop cannot pass vacuously for a tool whose feature
///    toggle is off, and G7 pins the `readOnlyBlocked` label against the
///    Read-Only gate it mirrors.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final agentSrc = File('lib/core/agent_service.dart').readAsStringSync();

  late ChatSession s;
  late Directory ledgerRoot;
  var setUpOk = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    // The session ledger resolves its root through path_provider — no channel
    // in a test, and a real documents dir otherwise. Pin it to a scratch dir
    // under the system temp root (the convention used across this suite) so
    // nothing this file does can write into the repo.
    ledgerRoot = Directory.systemTemp.createTempSync('ovid-plan-ledger-');
    SessionLedger.rootOverrideForTest = ledgerRoot;
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    PresetRegistry.clearCustom();
    s = ChatSession(id: 'plan-policy', title: 'P', model: 'm', mode: 'auto');
    app.sessions.insert(0, s);
    app.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);
    setUpOk = true;
  });

  tearDown(() async {
    // Ledger teardown is UNCONDITIONAL — a failed setUp must never leave the
    // root override pointing at a directory that no longer exists.
    if (setUpOk) await SessionLedger.I.close(s.id);
    SessionLedger.rootOverrideForTest = null;
    try {
      ledgerRoot.deleteSync(recursive: true);
    } catch (_) {}
    // A failed setUp already reported its own cause; touching `s` here would
    // throw LateInitializationError and bury it.
    if (!setUpOk) return;
    // Nothing may leak into the NEXT test. Every test here reuses the same
    // session id, so a run bucket left `busy` would queue the next test's
    // plan-mode transition instead of applying it — and the run-session
    // override, the custom presets and the composer's staged attachments are
    // process-global too.
    AgentService.I.runBucketForTest(s.id).activeRunId = null;
    AgentService.I.pendingAttachments.clear();
    AgentService.setRunSessionForTest('');
    s.planMode = false;
    s.planModePending = null;
    PresetRegistry.clearCustom();
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
  });

  Set<String> roster() => AgentService.I
      .toolsForTest()
      .map((t) => t['function']['name'] as String)
      .toSet();

  group('G1 — the run bucket no longer shadows the policy', () {
    test('no code writes a planMode field on a run bucket', () {
      // The removed field had five writers and zero readers. Anything that
      // reintroduces a per-run copy must fail here, because that copy is how
      // the gate and the UI drifted apart in the first place.
      expect(agentSrc, isNot(contains('run.planMode =')));
      expect(agentSrc, isNot(contains('_runFor(child.id).planMode')));
      expect(agentSrc, isNot(contains('_runResolved.planMode')));
    });

    test('the session field is the one source of truth', () {
      expect(AgentService.I.planMode, isFalse);
      s.planMode = true;
      expect(AgentService.I.planMode, isTrue);
      s.planMode = false;
      expect(AgentService.I.planMode, isFalse);
    });
  });

  group('G2 — plan-mode transitions honour the turn boundary', () {
    test('a transition requested mid-turn is queued, not applied', () {
      AgentService.I.runBucketForTest(s.id).activeRunId = 'run-live';
      addTearDown(() {
        AgentService.I.runBucketForTest(s.id).activeRunId = null;
      });

      AgentService.I.planMode = true;

      expect(s.planMode, isFalse, reason: 'the in-flight turn keeps its policy');
      expect(s.planModePending, isTrue);
      expect(AgentService.I.planModePending, isTrue, reason: 'UI projection');

      // The turn boundary lands it.
      AgentService.I.applyPendingPlanModeForTest(s);
      expect(s.planMode, isTrue);
      expect(s.planModePending, isNull);
      expect(AgentService.I.planModePending, isFalse);
    });

    test('a queued exit is also landed at the boundary', () {
      s.planMode = true;
      AgentService.I.runBucketForTest(s.id).activeRunId = 'run-live';
      addTearDown(() {
        AgentService.I.runBucketForTest(s.id).activeRunId = null;
      });

      AgentService.I.planMode = false;
      expect(s.planMode, isTrue, reason: 'queued, not applied');
      expect(s.planModePending, isFalse);

      AgentService.I.applyPendingPlanModeForTest(s);
      expect(s.planMode, isFalse);
      expect(s.planModePending, isNull);
    });

    test('an idle session applies immediately (no queue, no latency)', () {
      AgentService.I.planMode = true;
      expect(s.planMode, isTrue);
      expect(s.planModePending, isNull);
    });

    test('approving exit_plan_mode opens the gate NOW, not next turn',
        () async {
      // The approval is an explicit decision tied to THIS tool result and the
      // model is about to start building. Queueing it would lock the approved
      // plan out of the very tools it just earned.
      s.planMode = true;
      AgentService.I.runBucketForTest(s.id).activeRunId = 'run-live';
      addTearDown(() {
        AgentService.I.runBucketForTest(s.id).activeRunId = null;
      });

      final f = AgentService.I.dispatchForTest('exit_plan_mode', {
        'plan': 'Do the thing',
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(AgentService.I.pendingApproval, isNotNull);
      AgentService.I.pendingApproval!.answers['plan_exit'] = 'Yes';
      AgentService.I.approve(true);
      final out = await f;

      expect(out, contains('approved'));
      expect(s.planMode, isFalse, reason: 'immediate, not queued');
      expect(s.planModePending, isNull);
    });

    test('a mid-turn entry keeps the gate open for the rest of that turn',
        () async {
      s.planMode = false;
      AgentService.I.runBucketForTest(s.id).activeRunId = 'run-live';
      addTearDown(() {
        AgentService.I.runBucketForTest(s.id).activeRunId = null;
      });
      AgentService.I.planMode = true;
      // `device_tap` rather than `file_write`: the point is only whether the
      // GATE refuses, and a file tool that is let through would really write
      // into the repo. The probe is hermetic AND decisive — the plan gate runs
      // BEFORE the Control-mode switch in `_dispatchInner`, so a
      // wrongly-active gate would still be the first refusal (the assertion
      // fails), while a correctly-open gate falls through to
      // `DENIED: … requires Control mode` and never taps anything.
      String out;
      try {
        out = await AgentService.I.dispatchForTest('device_tap', {
          'x': 1,
          'y': 1,
        });
      } on Object catch (e) {
        out = 'ran past the gate: $e';
      }
      expect(
        out,
        isNot(contains('PLAN MODE ACTIVE')),
        reason: 'the turn started outside plan mode and finishes outside it',
      );
    });

    test('planModePending round-trips through the session JSON', () {
      final back = ChatSession.fromJson(
        ChatSession(
          id: 'p',
          title: 'P',
          model: 'm',
          planModePending: true,
        ).toJson(),
      );
      expect(back.planModePending, isTrue);
      final legacy = ChatSession.fromJson({
        'id': 'p',
        'title': 'P',
        'model': 'm',
      });
      expect(legacy.planModePending, isNull);
    });
  });

  group('G3 — a preset may pin the model and temperature of its runs', () {
    test('the pins round-trip and clear', () {
      const p = AgentPreset(
        id: 'cheap-plan',
        label: 'Cheap plan',
        description: 'd',
        model: 'tiny-model',
        temperature: 0.2,
      );
      final back = AgentPreset.fromJson(p.toJson());
      expect(back.model, 'tiny-model');
      expect(back.temperature, 0.2);

      expect(back.copyWith(clearModel: true).model, isNull);
      expect(back.copyWith(clearTemperature: true).temperature, isNull);
      expect(back.copyWith(model: 'other').model, 'other');
      expect(back.copyWith(temperature: 0.5).temperature, 0.5);
      // An unset pin stays unset — never a synthetic default injected.
      expect(const AgentPreset(id: 'a', label: 'A', description: '').model,
          isNull);
      expect(
        const AgentPreset(id: 'a', label: 'A', description: '').temperature,
        isNull,
      );
    });

    test('a custom preset persists its pins', () async {
      await AppState.I.saveCustomPreset(
        const AgentPreset(
          id: 'pinned',
          label: 'Pinned',
          description: 'd',
          model: 'tiny',
          temperature: 0.0,
        ),
      );
      final p = PresetRegistry.byId('pinned');
      expect(p.model, 'tiny');
      // 0.0 is a real value, not "unset" — it must survive the round-trip.
      expect(p.temperature, 0.0);
    });

    test('the run snapshot carries both pins', () {
      // The snapshot is what the request builders read; it must exist as a
      // run-scoped field for the same reason modelSnapshot does (a mid-run
      // picker switch must not change the in-flight run).
      expect(agentSrc, contains('double? temperatureSnapshot;'));
      expect(agentSrc, contains('bucket.temperatureSnapshot ='));
      expect(agentSrc, contains("body['temperature'] = presetTemp;"));
    });
  });

  group('G4 — the roster is an exact projection of the gate', () {
    test('planning hides every tool the gate would refuse', () {
      final before = roster();
      expect(before, contains('file_write'));
      expect(before, contains('fs_edit'));
      expect(before, contains('commit'));
      expect(before, contains('dispatch_agent'));

      s.planMode = true;
      final during = roster();
      for (final t in const [
        'file_write',
        'fs_edit',
        'commit',
        'run_code',
        'repo_sync',
        'dispatch_agent',
        'generate_image',
      ]) {
        // Assert the POLICY first. `repo_sync` (GitHub-sync toggle) and
        // `generate_image` (Image Studio plugin) are only in the base roster
        // when their feature is on, so "not offered" alone could pass
        // vacuously for them; the allowlist claim is falsifiable either way.
        expect(
          PlanModePolicy.allows(t),
          isFalse,
          reason: '$t must not be on the plan allowlist',
        );
        expect(
          during.contains(t),
          isFalse,
          reason: '$t is refused by the gate, so it must not be offered',
        );
      }
      // The planning toolset stays fully available.
      expect(
        during,
        containsAll(<String>[
          'file_read',
          'fs_grep',
          'run_shell',
          'git_log',
          'todo_write',
          'ask_user_question',
          'exit_plan_mode',
        ]),
      );
      // And leaving plan mode restores the full roster.
      s.planMode = false;
      expect(roster(), contains('file_write'));
    });

    test('a harness tool the gate refuses is not offered either', () {
      // `dispatch_agent` is a deliberate escape hatch OUT of plan mode, so the
      // gate refuses it — which means the roster must not advertise it. This is
      // the drift the old `rosterAllows` (harness tools always visible) had.
      s.planMode = true;
      expect(roster().contains('dispatch_agent'), isFalse);
    });
  });

  group('G5 — the plan policy is user-authorable', () {
    test('a preset plan allowlist replaces the built-in policy', () async {
      await AppState.I.saveCustomPreset(
        const AgentPreset(
          id: 'wide-plan',
          label: 'Wide plan',
          description: 'd',
          // `commit` is here as the GATE probe below: it is NOT on the built-in
          // allowlist, so it distinguishes "the preset's policy reached the
          // gate" from "the built-in policy is still in force".
          planAllowedTools: ['file_read', 'file_write', 'run_shell', 'commit'],
        ),
      );
      s
        ..presetId = 'wide-plan'
        ..planMode = true;

      // Now OFFERED by the preset's own policy: the roster projects the same
      // resolved set the gate consults, and the probe below proves the gate
      // really reads it — without dispatching anything that writes.
      expect(roster(), contains('file_write'));
      // The gate reads the SAME resolved set the roster projected — asserted
      // with `commit`, which is on the preset's list and NOT on the built-in
      // allowlist. The probe is decisive for that claim and inert for the repo:
      // the handler returns "no pending changes" before it can push anything,
      // and nothing in this file stages a change.
      expect(
        await AgentService.I.dispatchForTest('commit', {'message': 'm'}),
        'no pending changes',
        reason: 'the custom plan policy must reach the GATE, not just the '
            'roster — and it must do so without touching the repo',
      );
      // A tool outside the custom list is refused, so a custom policy is a
      // REPLACEMENT, not an additive escape from the default deny.
      expect(
        await AgentService.I.dispatchForTest('git_log', {}),
        contains('PLAN MODE ACTIVE'),
      );
    });

    test('an empty plan allowlist falls back to the built-in policy', () {
      expect(
        PresetRegistry.planPolicyFor(PresetRegistry.byId('standard')),
        PlanModePolicy.allowedTools,
      );
      expect(
        PresetRegistry.planPolicyFor(PresetRegistry.byId('plan')),
        PlanModePolicy.allowedTools,
      );
    });
  });

  group('G6 — /plan keeps what the composer already staged', () {
    test('staged attachments survive the command', () async {
      AgentService.I.pendingAttachments.add((
        name: 'notes.txt',
        path: '/tmp/notes.txt',
        size: 12,
      ));
      addTearDown(AgentService.I.pendingAttachments.clear);

      final res = await CommandService.I.execute('/plan');
      expect(res, isNotNull);
      // The whole line: singular/plural is real behaviour, and the count is
      // the only signal the user gets that the upload rode along.
      expect(res!.feedback, 'Plan mode on — 1 attachment will be included.');
      expect(res.prompt, isNotEmpty);
      expect(
        AgentService.I.pendingAttachments.length,
        1,
        reason: 'entering plan mode must not drop the user\'s upload',
      );

      // … and the plural form, so the singular branch is not a hardcode.
      AgentService.I.pendingAttachments.add((
        name: 'more.txt',
        path: '/tmp/more.txt',
        size: 3,
      ));
      final two = await CommandService.I.execute('/plan');
      expect(two!.feedback, 'Plan mode on — 2 attachments will be included.');
    });

    test('no attachments → the plain confirmation', () async {
      final res = await CommandService.I.execute('/plan');
      expect(res!.feedback, 'Plan mode on.');
    });
  });

  group('G7 — one definition of the policy', () {
    test('the service allowlist IS the policy module set', () {
      expect(AgentService.planModeAllowedToolsForTest, PlanModePolicy.allowedTools);
    });

    test('the preset harness set IS the policy module set', () {
      expect(PresetRegistry.harnessToolsForTest, PlanModePolicy.harnessTools);
    });

    test('the briefing is injected for every entry point', () {
      // One string, one injection site: `/plan`, the chip and the plan preset
      // all set the same session flag, and the prompt reads it. The system
      // template carries a TOKEN that `buildSys()` swaps for the briefing, so
      // the section can sit in the template without being in the prompt when
      // plan mode is off. All three halves of that splice are pinned.
      //
      // This used to assert a `${planMode ? PlanModePolicy.promptSection :`
      // literal — interpolation syntax that appears NOWHERE in the file (the
      // source writes the ternary as plain Dart), so it could never pass.
      expect(
        agentSrc,
        contains("const planSectionToken = '<<<PLAN_MODE_SECTION>>>';"),
      );
      expect(agentSrc, contains(r'$planSectionToken'));
      expect(agentSrc, contains('sysTemplate.replaceAll('));
      expect(agentSrc, contains('planMode ? PlanModePolicy.promptSection'));
      // And the briefing really is the module's text, not a second copy.
      expect(PlanModePolicy.promptSection, contains('READ-ONLY'));
    });

    test('the policy module owns the settings catalogue', () {
      expect(PlanModePolicy.catalogue, contains('run_shell'));
      expect(PlanModePolicy.catalogue, contains('file_write'));
      expect(PlanModePolicy.allows('file_read'), isTrue);
      expect(PlanModePolicy.allows('file_write'), isFalse);
      expect(PlanModePolicy.allows('file_write', policy: {'file_write'}), isTrue);
    });

    test('the Read-Only label matches the Read-Only gate', () {
      // `readOnlyBlocked` is the `*` the preset editor draws over a catalogue
      // chip; the module documents it as "kept here, beside catalogue, so the
      // label can never drift from the gate". These are the three names the
      // gate refuses for EVERY argument (`AgentService._readOnlyBlock`).
      const gateRefusesAlways = {'commit', 'file_write', 'run_code'};
      // Scoped to the gate's own body — the `fs_edit` case is where the
      // unconditional-refusal list ends and the argument-dependent cases begin.
      final roStart = agentSrc.indexOf('String? _readOnlyBlock(');
      final roGate = agentSrc.substring(
        roStart,
        agentSrc.indexOf("case 'fs_edit':", roStart),
      );
      for (final t in gateRefusesAlways) {
        expect(
          PlanModePolicy.readOnlyBlocked,
          contains(t),
          reason: '$t is refused by the Read-Only gate, so the picker must '
              'say so — otherwise it advertises a tool that will be rejected',
        );
        expect(
          roGate,
          contains("case '$t':"),
          reason: 'the Read-Only gate must still refuse $t unconditionally',
        );
      }
      // `fs_edit` is marked too: only its `view` subcommand survives the gate,
      // and the catalogue entry IS the editing use.
      expect(PlanModePolicy.readOnlyBlocked, contains('fs_edit'));
      // `run_shell` must NOT be marked — a read-only command genuinely runs in
      // Read-Only mode, so the label would be a lie in the other direction.
      expect(
        PlanModePolicy.readOnlyBlocked,
        isNot(contains('run_shell')),
        reason: 'read-only shell commands do run — labelling it would lie',
      );
    });
  });
}
