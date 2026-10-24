import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/background_notifications.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/push_payload_mapper.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('channel config', () {
    test('three channels with the requested importance and default sound', () {
      expect(OvidChannel.agentUpdates.importance, ChannelImportance.high);
      expect(OvidChannel.schedulerResults.importance, ChannelImportance.normal);
      expect(OvidChannel.backgroundStatus.importance, ChannelImportance.low);
      expect(OvidChannel.agentUpdates.defaultSound, NotificationSound.chime);
      expect(OvidChannel.schedulerResults.defaultSound, NotificationSound.chime);
      expect(OvidChannel.backgroundStatus.defaultSound, NotificationSound.silent);
      expect(OvidChannel.backgroundStatus.soundConfigurable, isFalse);
    });

    test('ids are new, versioned and per sound (channel sounds are immutable)', () {
      expect(
        NotificationChannelIds.id(OvidChannel.agentUpdates, NotificationSound.chime),
        'ovid_agent_updates.chime.v1',
      );
      expect(
        NotificationChannelIds.id(
          OvidChannel.schedulerResults,
          NotificationSound.system,
        ),
        'ovid_scheduler_results.system.v1',
      );
      final all = {
        for (final c in OvidChannel.values)
          for (final s in NotificationSound.values) NotificationChannelIds.id(c, s),
      };
      expect(all, hasLength(9));
      for (final legacy in NotificationChannelIds.legacy) {
        expect(all, isNot(contains(legacy)));
      }
      expect(
        NotificationChannelIds.stale(OvidChannel.agentUpdates, NotificationSound.system),
        ['ovid_agent_updates.chime.v1', 'ovid_agent_updates.silent.v1'],
      );
    });

    test('the Kotlin side uses the same id formula and legacy list', () {
      final kt = File(
        'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidNotifications.kt',
      ).readAsStringSync();
      expect(kt, contains(r'"ovid_$key.$sound.$VERSION"'));
      expect(kt, contains('const val VERSION = "${NotificationChannelIds.version}"'));
      for (final c in OvidChannel.values) {
        expect(kt, contains('"${c.key}"'));
      }
      for (final legacy in NotificationChannelIds.legacy) {
        expect(kt, contains('"$legacy"'));
      }
    });

    test('settings default on/chime, status stays silent, prefs round-trip', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final defaults = NotificationSettings.fromPrefs(prefs);
      expect(defaults.enabled.values, everyElement(isTrue));
      expect(defaults.activeChannelIds, {
        OvidChannel.agentUpdates: 'ovid_agent_updates.chime.v1',
        OvidChannel.schedulerResults: 'ovid_scheduler_results.chime.v1',
        OvidChannel.backgroundStatus: 'ovid_background_status.silent.v1',
      });
      final custom = NotificationSettings(
        enabled: {OvidChannel.schedulerResults: false},
        sounds: {
          OvidChannel.agentUpdates: NotificationSound.system,
          OvidChannel.backgroundStatus: NotificationSound.chime,
        },
      );
      expect(custom.sounds[OvidChannel.backgroundStatus], NotificationSound.silent);
      await custom.save(prefs);
      final back = NotificationSettings.fromPrefs(prefs);
      expect(back.enabled[OvidChannel.schedulerResults], isFalse);
      expect(back.sounds[OvidChannel.agentUpdates], NotificationSound.system);
      expect(back.toPlatformArgs(), {
        'sounds': {'agent_updates': 'system', 'scheduler_results': 'chime'},
        'enabled': {
          'agent_updates': true,
          'scheduler_results': false,
          'background_status': true,
        },
      });
    });
  });

  group('routing payloads', () {
    test('each kind lands on its channel and opens the right route', () {
      final done = OvidNotification.agentFinished(
        sessionId: 's1',
        sessionTitle: 'Trip plan',
        reply: 'Here is your **itinerary**.',
      );
      expect(done.channel, OvidChannel.agentUpdates);
      expect(done.route, '/c/s1');
      expect(done.body, 'Trip plan — Here is your itinerary.');
      expect(done.toPlatformArgs(), {
        'channel': 'agent_updates',
        'id': done.id,
        'title': 'Ovid finished',
        'body': 'Trip plan — Here is your itinerary.',
        'route': '/c/s1',
      });

      final ask = OvidNotification.needsInput(
        sessionId: 's1',
        sessionTitle: 'Trip plan',
        summary: 'Run shell: rm -rf build',
        question: false,
      );
      expect(ask.kind, OvidNotificationKind.agentNeedsApproval);
      expect(ask.route, '/c/s1');
      expect(
        OvidNotification.needsInput(
          sessionId: 's1',
          sessionTitle: '',
          summary: 'Which city?',
          question: true,
        ).kind,
        OvidNotificationKind.agentNeedsInput,
      );

      final ok = OvidNotification.scheduleResult(
        sessionId: 's2',
        prompt: 'Summarise my inbox',
        success: true,
        summary: '3 new mails, nothing urgent.',
      );
      expect(ok.channel, OvidChannel.schedulerResults);
      expect(ok.route, '/schedule/s2');
      expect(ok.title, 'Scheduled task done: Summarise my inbox');
      final bad = OvidNotification.scheduleResult(
        sessionId: 's2',
        prompt: 'Summarise my inbox',
        success: false,
        error: 'Provider/model setup required',
      );
      expect(bad.kind, OvidNotificationKind.scheduleFailed);
      expect(bad.body, 'Provider/model setup required');

      final images = OvidNotification.agentFinished(
        sessionId: 's3',
        sessionTitle: 'Logos',
        reply: 'Done',
        images: 4,
      );
      expect(images.kind, OvidNotificationKind.jobDone);
      expect(images.title, '4 images ready');
    });

    test('push payloads preserve agent scheduler and background metadata', () {
      final failed = PushPayloadMapper.fromData({
        'kind': 'agentFailed',
        'channel': 'agent_updates',
        'sessionId': 'session-failed',
        'route': '/c/session-failed',
        'title': 'Ovid could not finish this run',
        'body': 'The run stopped.',
      });
      expect(failed, isNotNull);
      expect(failed!.kind, OvidNotificationKind.agentFailed);
      expect(failed.channel, OvidChannel.agentUpdates);
      expect(failed.sessionId, 'session-failed');
      expect(failed.route, '/c/session-failed');

      final scheduled = PushPayloadMapper.fromData({
        'kind': 'scheduleSucceeded',
        'channel': 'scheduler_results',
        'sessionId': 'session-scheduled',
        'route': '/schedule/session-scheduled',
        'title': 'Scheduled task done',
        'body': 'Tap to see the result.',
      });
      expect(scheduled, isNotNull);
      expect(scheduled!.kind, OvidNotificationKind.scheduleSucceeded);
      expect(scheduled.channel, OvidChannel.schedulerResults);
      expect(scheduled.route, '/schedule/session-scheduled');

      final status = PushPayloadMapper.fromData({
        'kind': 'backgroundStatus',
        'channel': 'background_status',
        'route': '/settings',
        'title': 'Ovid is active',
        'body': 'Background work is running.',
      });
      expect(status, isNotNull);
      expect(status!.kind, OvidNotificationKind.backgroundStatus);
      expect(status.channel, OvidChannel.backgroundStatus);
      expect(status.channel.defaultSound, NotificationSound.silent);
      expect(status.route, '/settings');
    });

    test('push payloads without explicit consistent metadata are dropped', () {
      expect(PushPayloadMapper.fromData({'route': '/c/session'}), isNull);
      expect(
        PushPayloadMapper.fromData({
          'kind': 'agentFailed',
          'channel': 'scheduler_results',
          'sessionId': 'session-failed',
          'route': '/c/session-failed',
        }),
        isNull,
      );
      expect(
        PushPayloadMapper.fromData({
          'kind': 'scheduleFailed',
          'channel': 'scheduler_results',
          'sessionId': 'session-scheduled',
          'route': '/c/session-scheduled',
        }),
        isNull,
      );
      expect(
        PushPayloadMapper.fromData({
          'kind': 'agentFinished',
          'channel': 'agent_updates',
          'route': '/c/missing-session',
        }),
        isNull,
      );
    });

    test('ids are stable, in range, and replace per session', () {
      final a = OvidNotification.agentFinished(
        sessionId: 's1',
        sessionTitle: '',
        reply: 'one',
      );
      final b = OvidNotification.needsInput(
        sessionId: 's1',
        sessionTitle: '',
        summary: 'two',
        question: true,
      );
      final c = OvidNotification.agentFinished(
        sessionId: 's2',
        sessionTitle: '',
        reply: 'one',
      );
      expect(a.id, b.id, reason: 'latest state of a chat replaces the older one');
      expect(a.id, isNot(c.id));
      for (final n in [a, b, c]) {
        expect(n.id, inInclusiveRange(2000, 2000 + 0xfffff));
      }
      // FNV-1a of a fixed key is process-independent.
      expect(OvidNotification(
        kind: OvidNotificationKind.jobDone,
        title: '',
        body: '',
        route: '/',
        key: 'job:sandbox',
      ).id, 2000 + (0x7ba1eb8d & 0xfffff));
    });

    test('summary strips markdown/code and caps length', () {
      expect(notificationSummary('# Title\n\n```dart\nx\n```\n**bold** [link](http://a)'),
          'Title [code] bold link');
      final long = notificationSummary('word ' * 100, max: 40);
      expect(long.length, lessThanOrEqualTo(40));
      expect(long.endsWith('…'), isTrue);
    });
  });

  group('quiet hours', () {
    test('a window that wraps midnight is handled', () {
      final s = NotificationSettings(
        quietHoursEnabled: true,
        quietHoursStartMinutes: 22 * 60,
        quietHoursEndMinutes: 8 * 60,
      );
      expect(s.inQuietHours(DateTime(2026, 10, 21, 23, 30)), isTrue);
      expect(s.inQuietHours(DateTime(2026, 10, 21, 3, 0)), isTrue);
      expect(s.inQuietHours(DateTime(2026, 10, 21, 8, 0)), isFalse);
      expect(s.inQuietHours(DateTime(2026, 10, 21, 12, 0)), isFalse);
    });

    test('a same-day window is handled and disabled means never quiet', () {
      final s = NotificationSettings(
        quietHoursEnabled: true,
        quietHoursStartMinutes: 13 * 60,
        quietHoursEndMinutes: 14 * 60,
      );
      expect(s.inQuietHours(DateTime(2026, 10, 21, 13, 30)), isTrue);
      expect(s.inQuietHours(DateTime(2026, 10, 21, 14, 30)), isFalse);
      s.quietHoursEnabled = false;
      expect(s.inQuietHours(DateTime(2026, 10, 21, 13, 30)), isFalse);
    });

    test('quiet hours persist with the other notification settings', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final saved = NotificationSettings(
        quietHoursEnabled: true,
        quietHoursStartMinutes: 21 * 60 + 30,
        quietHoursEndMinutes: 7 * 60 + 15,
      );
      await saved.save(prefs);
      final restored = NotificationSettings.fromPrefs(prefs);
      expect(restored.quietHoursEnabled, isTrue);
      expect(restored.quietHoursStartMinutes, 21 * 60 + 30);
      expect(restored.quietHoursEndMinutes, 7 * 60 + 15);
    });

    test('an empty window never suppresses', () {
      final s = NotificationSettings(
        quietHoursEnabled: true,
        quietHoursStartMinutes: 9 * 60,
        quietHoursEndMinutes: 9 * 60,
      );
      expect(s.inQuietHours(DateTime(2026, 10, 21, 9, 0)), isFalse);
    });
  });

  group('delivery decision (no duplicates in the foreground)', () {
    final n = OvidNotification.agentFinished(
      sessionId: 's1',
      sessionTitle: '',
      reply: 'x',
    );
    NotificationDelivery decide({
      bool master = true,
      bool channel = true,
      bool fg = false,
      String? visible,
    }) => decideDelivery(
      notification: n,
      masterEnabled: master,
      channelEnabled: channel,
      appInForeground: fg,
      visibleSessionId: visible,
    );

    test('matrix', () {
      expect(decide(), NotificationDelivery.system);
      expect(decide(fg: true), NotificationDelivery.inApp);
      expect(decide(fg: true, visible: 's1'), NotificationDelivery.suppressed);
      expect(decide(fg: true, visible: 's2'), NotificationDelivery.inApp);
      expect(decide(visible: 's1'), NotificationDelivery.system,
          reason: 'backgrounded: the visible chat is not on screen');
      expect(decide(master: false), NotificationDelivery.suppressed);
      expect(decide(channel: false), NotificationDelivery.suppressed);
    });
  });

  group('BackgroundNotifier', () {
    final notifier = BackgroundNotifier.I;
    late List<(String, Object?)> calls;
    late List<OvidNotification> shownInApp;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      notifier.resetForTest();
      calls = [];
      shownInApp = [];
      notifier.invokeOverrideForTest = (m, a) async {
        calls.add((m, a));
        return true;
      };
      notifier.inAppPresenter = shownInApp.add;
    });
    tearDown(notifier.resetForTest);

    OvidNotification sample() => OvidNotification.scheduleResult(
      sessionId: 'nope-${calls.length}',
      prompt: 'p',
      success: true,
    );

    test('background → native notifyPost with the payload', () async {
      notifier.foregroundOverrideForTest = () => false;
      final n = sample();
      expect(await notifier.post(n), NotificationDelivery.system);
      expect(calls.single.$1, 'notifyPost');
      expect(calls.single.$2, n.toPlatformArgs());
      expect(shownInApp, isEmpty);
    });

    test('foreground → in-app only, never a system duplicate', () async {
      notifier.foregroundOverrideForTest = () => true;
      expect(await notifier.post(sample()), NotificationDelivery.inApp);
      expect(calls, isEmpty);
      expect(shownInApp, hasLength(1));
    });

    test('visible chat suppression resolves local and server session ids', () async {
      CloudSessionStore.installForTest(
        CloudSessionStore.forTest(
          idMap: {'local-visible-chat': 'server-visible-chat'},
          rest: CloudRestClient(
            httpClient: MockClient((request) async => http.Response('{}', 200)),
            headers: CloudHeaders.forTest(),
            restBase: 'https://cloud.test',
          ),
        ),
      );
      addTearDown(CloudSessionStore.resetForTest);
      AppState.I.activeSessionId = 'local-visible-chat';
      addTearDown(() => AppState.I.activeSessionId = null);
      notifier.foregroundOverrideForTest = () => true;

      final visible = OvidNotification.agentFinished(
        sessionId: 'server-visible-chat',
        sessionTitle: '',
        reply: 'Visible reply',
      );
      expect(await notifier.post(visible), NotificationDelivery.suppressed);
      expect(shownInApp, isEmpty);

      final other = OvidNotification.agentFinished(
        sessionId: 'server-other-chat',
        sessionTitle: '',
        reply: 'Other reply',
      );
      expect(await notifier.post(other), NotificationDelivery.inApp);
      expect(shownInApp, [other]);
    });

    test('per-channel switch and the master switch are respected', () async {
      notifier.foregroundOverrideForTest = () => false;
      await notifier.setChannelEnabled(OvidChannel.schedulerResults, false);
      expect(calls.last.$1, 'notifyConfigure');
      calls.clear();
      expect(await notifier.post(sample()), NotificationDelivery.suppressed);
      expect(calls, isEmpty);
      await notifier.setChannelEnabled(OvidChannel.schedulerResults, true);
      calls.clear();
      await AppState.I.setNotificationsEnabled(false);
      addTearDown(() => AppState.I.setNotificationsEnabled(true));
      expect(await notifier.post(sample()), NotificationDelivery.suppressed);
      expect(calls.where((c) => c.$1 == 'notifyPost'), isEmpty);
    });

    test('changing a sound reconfigures channels natively', () async {
      await notifier.setChannelSound(
        OvidChannel.agentUpdates,
        NotificationSound.system,
      );
      final args = calls.last.$2 as Map;
      expect(calls.last.$1, 'notifyConfigure');
      expect((args['sounds'] as Map)['agent_updates'], 'system');
      // The status channel cannot be given a sound.
      calls.clear();
      await notifier.setChannelSound(
        OvidChannel.backgroundStatus,
        NotificationSound.chime,
      );
      expect(calls, isEmpty);
    });

    test('init configures channels', () async {
      await notifier.init();
      expect(calls.map((c) => c.$1), ['notifyConfigure']);
    });

    test(
      'boot init coalesces callers and completes after channel configuration',
      () async {
        final gate = Completer<void>();
        notifier.invokeOverrideForTest = (method, args) async {
          calls.add((method, args));
          if (method == 'notifyConfigure') await gate.future;
          return true;
        };

        var completed = false;
        final first = notifier.init().then((_) => completed = true);
        final second = notifier.init();
        await Future<void>.delayed(Duration.zero);
        expect(calls.map((c) => c.$1), ['notifyConfigure']);
        expect(completed, isFalse);

        gate.complete();
        await first;
        await second;
        expect(completed, isTrue);
        expect(calls.map((c) => c.$1), ['notifyConfigure']);
      },
    );
  });

  group('original notification sound', () {
    test('res/raw/ovid_chime.wav: 44.1 kHz mono 16-bit, 0.5–0.8 s, ~-3 dBFS', () {
      final bytes = File('android/app/src/main/res/raw/ovid_chime.wav')
          .readAsBytesSync();
      final data = ByteData.sublistView(bytes);
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
      expect(data.getUint16(20, Endian.little), 1, reason: 'PCM');
      expect(data.getUint16(22, Endian.little), 1, reason: 'mono');
      expect(data.getUint32(24, Endian.little), 44100);
      expect(data.getUint16(34, Endian.little), 16);
      expect(String.fromCharCodes(bytes.sublist(36, 40)), 'data');
      final size = data.getUint32(40, Endian.little);
      final seconds = size / 2 / 44100;
      expect(seconds, inInclusiveRange(0.5, 0.8));
      var peak = 0;
      for (var i = 44; i + 1 < 44 + size; i += 2) {
        final v = data.getInt16(i, Endian.little).abs();
        if (v > peak) peak = v;
      }
      final peakDb = 20 * math.log(peak / 32767) / math.ln10;
      expect(peakDb, closeTo(-3.0, 0.1));
      // Soft attack and a faded tail: no click at either end.
      expect(data.getInt16(44, Endian.little).abs(), lessThan(200));
      expect(data.getInt16(44 + size - 2, Endian.little).abs(), lessThan(200));
    });

    test('the generator script is committed and deterministic', () async {
      final script = File('tool/gen_notification_sound.py');
      expect(script.existsSync(), isTrue);
      final ProcessResult r;
      try {
        r = await Process.run('python3', [script.path, '--check']);
      } on ProcessException {
        markTestSkipped('python3 not available');
        return;
      }
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    });

    test('release builds keep the resource referenced only by URI', () {
      final keep = File('android/app/src/main/res/raw/keep.xml').readAsStringSync();
      expect(keep, contains('tools:keep="@raw/ovid_chime"'));
    });
  });
}
