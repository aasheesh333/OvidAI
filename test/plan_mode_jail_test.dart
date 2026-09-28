import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/plan_mode.dart';
import 'package:ovid_ai/core/state.dart';

/// Plan-mode WORKSPACE JAIL (2026-09-28).
///
/// Owner rule, verbatim: "plan mode sirf current dir me hi kaam kare not
/// outside of current directory kisi bhi mode me hone per bhi" — plan mode works
/// only inside the current directory, in EVERY access mode: Studio's bound repo
/// folder, every other mode's session-isolated workspace, and Full Access
/// included (planning does not widen with the access mode).
///
/// The other half of the rule is "plan mode me agent koi bhi permission naa
/// puchhe": planning must not raise an approval card either. So every refusal
/// asserted here ALSO asserts `pendingApproval` stayed null — a jail that asks
/// permission is not the jail that was requested.
///
/// WHY THE ROOT IS FORCED. The real resolver goes through path_provider and the
/// repo registry, and neither is reachable from a unit test: without
/// [AgentService.planModeRootForTest] it throws, both gates fall back to "no
/// jail", and this suite would go green while proving nothing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A session-isolated workspace — the shape the jail root has outside Studio.
  const jail = '/data/user/0/com.dhanuk.ovidai/files/sessions/s-1';
  // The canonical spelling of the SAME directory: Android aliases
  // /data/user/0/<pkg> to /data/data/<pkg> and planModeRoot() canonicalises.
  // The jail must accept both spellings, or it would falsely refuse the very
  // path the system prompt documents as the working folder.
  const jailAlias = '/data/data/com.dhanuk.ovidai/files/sessions/s-1';
  const sibling = '/data/user/0/com.dhanuk.ovidai/files/sessions/s-2';

  Set<String> outside(String cmd, [String root = jail]) =>
      AgentService.shellPathsOutsideRoot(cmd, root);

  group('plan jail: shellPathsOutsideRoot', () {
    test('an absolute path outside the working directory is caught', () {
      expect(outside('cat /sdcard/notes.txt'), contains('/sdcard/notes.txt'));
      expect(
        outside('cat /data/user/0/com.other.app/files/x'),
        isNotEmpty,
        reason: "another app's data dir is outside the jail",
      );
      expect(
        outside('tail -n 20 $sibling/log'),
        isNotEmpty,
        reason: "another SESSION's workspace is outside the jail",
      );
    });

    test('paths inside the working directory are left alone', () {
      expect(outside('cat $jail/lib/main.dart'), isEmpty);
      expect(outside('cat $jail'), isEmpty, reason: 'the root itself is in');
      expect(outside('ls -la $jail/lib'), isEmpty);
      // Relative paths resolve against the root by definition — a jail that
      // broke ordinary research would be a jail nobody could use.
      expect(outside('cat lib/main.dart'), isEmpty);
      expect(outside('ls -la ./lib && wc -l lib/*.dart'), isEmpty);
      expect(outside('git log --oneline -5'), isEmpty);
      expect(outside("grep -rn 'TODO' lib test"), isEmpty);
    });

    test('a relative `..` climb out of the jail is caught', () {
      // The one escape that leaves the working directory without ever naming an
      // absolute path — the reason the scan is not limited to `/`-prefixed
      // tokens.
      expect(outside('cat ../../s-2/secrets.txt'), isNotEmpty);
      expect(outside('cat ../s-2/x'), isNotEmpty);
      expect(outside('cat lib/../../s-2/x'), isNotEmpty);
      expect(outside('cat ../s-1/x'), isEmpty, reason: 'climbs back inside');
    });

    test('a path carried in an assignment or flag value is caught', () {
      // Neither form starts with `/`, so a scan keyed on absolute-path tokens
      // misses both — and an assignment is the easiest way to smuggle an
      // outside path into a command that otherwise looks relative.
      expect(outside('TMPDIR=/sdcard/x tar czf o.tgz lib'), isNotEmpty);
      expect(outside('grep -r needle --include=$sibling/y'), isNotEmpty);
      expect(outside('TMPDIR=$jail/tmp tar czf o.tgz lib'), isEmpty);
    });

    test('read-only system paths stay exempt', () {
      // The jail is about the USER's files. Blocking `uname -a`, /proc or /bin
      // would break legitimate research for no security gain.
      expect(outside('uname -a'), isEmpty);
      expect(outside('cat /proc/self/status'), isEmpty);
      expect(outside('ls /sys/class/net'), isEmpty);
      expect(outside('ls /bin /usr/bin'), isEmpty);
      expect(outside('cat /etc/hosts'), isEmpty);
    });

    test('/tmp is NOT exempt', () {
      // This app's scratch dir is the sandbox prefix's own tmp (an absolute
      // path under the app data dir), so exempting /tmp would only have
      // widened the jail for nothing.
      expect(outside('cat /tmp/x'), isNotEmpty);
      expect(outside('cat /var/tmp/x'), isNotEmpty);
    });

    test("Android's /data/user/0 alias is treated as the same directory", () {
      expect(outside('cat $jailAlias/lib/main.dart'), isEmpty);
      expect(
        outside('cat $jail/lib/main.dart', jailAlias),
        isEmpty,
        reason: 'the jail holds in either spelling, both directions',
      );
      expect(
        outside('cat $jailAlias/../s-2/x'),
        isNotEmpty,
        reason: 'the alias must not become a way out either',
      );
    });

    test('an empty root disables the jail instead of refusing everything', () {
      // Failing open on an UNRESOLVABLE root is deliberate: no jail, but never
      // a plan agent that cannot read anything. Both gates share that fallback.
      expect(outside('cat /sdcard/x', ''), isEmpty);
    });
  });

  group('plan jail: the gate refuses reads outside the working directory', () {
    late ChatSession s;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      app.seenWelcomeVersion = AppState.welcomeVersion;
      AgentService.I.debugPauseScheduleTimerForTest(true);
      s = ChatSession(id: 'plan-jail', title: 'J', model: 'm', mode: 'auto')
        ..planMode = true;
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      AgentService.setRunSessionForTest(s.id);
      AgentService.planModeRootForTest = jail;
    });

    tearDown(() {
      s.planMode = false;
      s.mode = 'auto';
      AgentService.planModeRootForTest = null;
      AgentService.setRunSessionForTest('');
      AgentService.I.debugPauseScheduleTimerForTest(false);
      AppState.resetTestInstance();
    });

    Future<String> call(
      String tool, [
      Map<String, dynamic> args = const {},
    ]) async {
      try {
        return await AgentService.I.dispatchForTest(tool, args);
      } on Object catch (e) {
        // The gate LET THE TOOL THROUGH and it then hit an unmocked platform
        // channel. For this suite that is a pass: the assertion is about the
        // gate, not the tool's own IO.
        return 'TOOL_RAN_PAST_THE_GATE: $e';
      }
    }

    test('file_read outside the jail is refused with no card', () async {
      final out = await call('file_read', {'path': '/sdcard/notes.txt'});
      expect(out, contains('PLAN MODE'));
      expect(out, contains('working directory'));
      expect(
        AgentService.I.pendingApproval,
        isNull,
        reason: 'plan mode never raises a permission card',
      );
    });

    test("another session's workspace is refused", () async {
      expect(
        await call('file_read', {'path': '$sibling/x'}),
        contains('PLAN MODE'),
      );
      expect(AgentService.I.pendingApproval, isNull);
    });

    test('read_image, fs_glob and fs_grep are jailed too', () async {
      expect(
        await call('read_image', {'path': '/sdcard/DCIM/x.png'}),
        contains('PLAN MODE'),
      );
      expect(
        await call('fs_glob', {'pattern': '../../s-2/**/*.dart'}),
        contains('PLAN MODE'),
      );
      expect(
        await call('fs_grep', {
          'pattern': 'needle',
          'include': '$sibling/y.dart',
        }),
        contains('PLAN MODE'),
      );
      expect(AgentService.I.pendingApproval, isNull);
    });

    test('reads INSIDE the jail pass the gate', () async {
      for (final path in [
        'lib/main.dart',
        '$jail/lib/main.dart',
        '$jailAlias/lib/main.dart',
      ]) {
        final out = await call('file_read', {'path': path});
        expect(
          out,
          isNot(contains('PLAN MODE')),
          reason: '$path is inside the jail and must stay readable',
        );
      }
    });

    test('a shell command reaching outside the jail is refused', () async {
      final out = await call('run_shell', {'command': 'cat /sdcard/notes.txt'});
      expect(out, contains('PLAN MODE'));
      expect(out, contains('working directory'));
      expect(AgentService.I.pendingApproval, isNull);
    });

    test('job_start is refused too — no smuggling an outside read in',
        () async {
      final out = await call('job_start', {'command': 'cat $sibling/x'});
      expect(out, contains('PLAN MODE'));
      expect(AgentService.I.pendingApproval, isNull);
    });

    test('the jail holds in EVERY access mode, Full Access included', () async {
      // The "kisi bhi mode me hone per bhi" half of the rule: the jail is the
      // PLAN PHASE's boundary, not the access mode's, so switching to Full
      // Access must not widen it.
      for (final mode in const ['safe', 'auto', 'studio', 'drive', 'control']) {
        s.mode = mode;
        expect(
          await call('file_read', {'path': '/sdcard/notes.txt'}),
          contains('PLAN MODE'),
          reason: 'mode=$mode must stay jailed',
        );
        expect(
          AgentService.I.pendingApproval,
          isNull,
          reason: 'mode=$mode must not raise a card either',
        );
        expect(
          await call('run_shell', {'command': 'cat $sibling/x'}),
          contains('PLAN MODE'),
          reason: 'mode=$mode must jail the shell too',
        );
      }
    });

    test('leaving plan mode lifts the jail', () async {
      // Drive + plan off: the outside path is no longer plan-refused. (Drive is
      // used deliberately — in auto mode an outside path raises a real grant
      // card, which would block this test on a completer nobody answers.)
      s.mode = 'drive';
      s.planMode = false;
      expect(
        await call('file_read', {'path': '/sdcard/notes.txt'}),
        isNot(contains('PLAN MODE')),
        reason: 'the jail is a plan-mode boundary, not a permanent one',
      );
    });

    test('an unresolvable root degrades to no jail, not to a brick', () async {
      // planModeRoot() touches path_provider + the repo registry; if either
      // throws, planning must still work rather than refuse every read.
      AgentService.planModeRootForTest = null;
      expect(
        await call('file_read', {'path': 'lib/main.dart'}),
        isNot(contains('PLAN MODE')),
      );
    });
  });

  group('plan jail: the prompt names the real working directory', () {
    test('every placeholder resolves, for each mode', () {
      for (final mode in const [
        'studio',
        'drive',
        'auto',
        'safe',
        'control',
      ]) {
        final p = PlanModePolicy.promptSectionFor(root: jail, modeName: mode);
        expect(
          p,
          isNot(contains(PlanModePolicy.rootPlaceholder)),
          reason: mode,
        );
        expect(
          p,
          isNot(contains(PlanModePolicy.scopePlaceholder)),
          reason: mode,
        );
        expect(p, contains(jail), reason: 'the root must be stated: $mode');
        expect(p, contains('PLAN MODE'), reason: mode);
      }
    });

    test('studio says the repo folder is the whole scope', () {
      expect(
        PlanModePolicy.promptSectionFor(root: jail, modeName: 'studio'),
        contains('repo folder'),
      );
    });

    test('drive states that Full Access does not widen plan mode', () {
      expect(
        PlanModePolicy.promptSectionFor(root: jail, modeName: 'drive'),
        contains('does NOT widen'),
      );
    });

    test('other modes name the session-isolated workspace', () {
      expect(
        PlanModePolicy.promptSectionFor(root: jail, modeName: 'auto'),
        contains('session-isolated'),
      );
    });

    test('an unresolved root degrades to a pwd hint, never a raw placeholder',
        () {
      // A literal {PLAN_ROOT} in a system prompt is worse than no path at all:
      // the model would repeat it back to the user as if it were a directory.
      final p = PlanModePolicy.promptSectionFor(root: '', modeName: 'auto');
      expect(p, isNot(contains(PlanModePolicy.rootPlaceholder)));
      expect(p, isNot(contains(PlanModePolicy.scopePlaceholder)));
      expect(p, contains('pwd'));
      final n = PlanModePolicy.promptSectionFor(root: null, modeName: 'studio');
      expect(n, isNot(contains(PlanModePolicy.rootPlaceholder)));
      expect(n, contains('pwd'));
    });
  });
}
