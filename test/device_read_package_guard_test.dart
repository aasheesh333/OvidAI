import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/device_control_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

/// WS7 remainder (audit 2026-09-25): the sensitive-target guard on
/// `device_read` keyed only on `raw['package']`. A delta/`unchanged` read whose
/// native payload omits `package` yielded null -> `_isSensitiveDeviceTarget(null)`
/// -> false, so the read was treated as NOT sensitive and slipped through.
///
/// The ACTION path already fails closed here ("could not verify the live
/// foreground app"). The read path must match: when the payload carries no
/// package, verify with the cheap probe before returning any screen content.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux, () {
        try {
          return ffi.DynamicLibrary.open('libsqlite3.so.0');
        } catch (_) {
          return ffi.DynamicLibrary.open(
            '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
          );
        }
      });
    }
    app = AppState.I;
    await app.initialize();
  });

  setUp(() async {
    app.sessions.clear();
    app.activeSessionId = null;
  });

  late ChatSession s;
  late List<MethodCall> calls;
  late bool readCarriesPackage;
  late String readPackage;
  late Object? probeAnswer;

  setUp(() {
    s = ChatSession(id: 'rd-guard', title: 'S', model: 'm', mode: 'control');
    app.sessions.insert(0, s);
    app.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);
    calls = <MethodCall>[];
    readCarriesPackage = true;
    readPackage = 'com.example.notes';
    probeAnswer = {'package': 'com.example.notes'};

    const channel = MethodChannel('ovid/device-read-guard-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'deviceRead') {
        return {
          'status': 'ok',
          'full': false,
          if (readCarriesPackage) 'package': readPackage,
          'added': <dynamic>[
            {'handle': 1, 'class': 'TextView', 'text': 'balance \$4,213.88'},
          ],
          'changed': <dynamic>[],
          'removed': <dynamic>[],
        };
      }
      if (call.method == 'deviceForegroundPackage') return probeAnswer;
      return true;
    });
    DeviceControlService.setMethodChannelForTest(channel);
    addTearDown(() {
      DeviceControlService.setMethodChannelForTest(null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      AgentService.setRunSessionForTest('');
      app.activeSessionId = null;
      app.sessions.removeWhere((x) => x.id == s.id);
    });
  });

  test('a payload package that is sensitive still denies (regression)', () async {
    readPackage = 'com.paypal.android.p2pmobile';
    final out = await AgentService.I.dispatchForTest('device_read', {});
    expect(out, contains('DENIED'));
    expect(out, isNot(contains('balance')));
  });

  test('no package in the payload + sensitive probe answer denies', () async {
    readCarriesPackage = false;
    probeAnswer = {'package': 'com.paypal.android.p2pmobile'};
    final out = await AgentService.I.dispatchForTest('device_read', {});
    expect(out, contains('DENIED'),
        reason: 'a package-less read must not bypass the sensitive guard');
    expect(out, isNot(contains('balance')));
  });

  test('no package in the payload + unverifiable probe denies', () async {
    readCarriesPackage = false;
    // Not a Map with `package` -> the bridge falls back to readRaw, which here
    // also carries no package, so nothing can confirm the foreground app.
    probeAnswer = true;
    final out = await AgentService.I.dispatchForTest('device_read', {});
    expect(out, contains('could not verify'),
        reason: 'must fail closed like the action path, not silently allow');
    expect(out, isNot(contains('balance')));
  });

  test('no package in the payload + benign probe answer still reads', () async {
    readCarriesPackage = false;
    probeAnswer = {'package': 'com.example.notes'};
    final out = await AgentService.I.dispatchForTest('device_read', {});
    expect(out, contains('balance'),
        reason: 'verification must not over-block a benign foreground app');
    expect(out, isNot(contains('DENIED')));
  });
}
