import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/device_control_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

/// Control-mode finance guard (F-025): finance apps are blocked by signal, not
/// only by a short brand list, and a payment step inside any app (UPI PIN pad,
/// card form, purchase sheet) withholds the screen and refuses actions until a
/// clean full read.
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
  late bool readFull;
  late String screenText;

  setUp(() {
    s = ChatSession(
      id: 'finance-guard',
      title: 'S',
      model: 'm',
      mode: 'control',
    );
    app.sessions.insert(0, s);
    app.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);
    calls = <MethodCall>[];
    readCarriesPackage = true;
    readPackage = 'com.example.notes';
    probeAnswer = {'package': 'com.example.notes'};
    readFull = false;
    screenText = 'Order summary';
    AgentService.I.paymentScreenPackageForTest = null;

    const channel = MethodChannel('ovid/finance-guard-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'deviceRead') {
            return {
              'status': 'ok',
              'full': readFull,
              if (readCarriesPackage) 'package': readPackage,
              'added': <dynamic>[
                {'handle': 1, 'class': 'TextView', 'text': screenText},
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
      AgentService.I.paymentScreenPackageForTest = null;
      app.activeSessionId = null;
      app.sessions.removeWhere((x) => x.id == s.id);
    });
  });

  bool sensitive(String pkg) =>
      DeviceControlService.isSensitiveTargetForTest(packageName: pkg);

  group('finance apps are blocked', () {
    test('Indian UPI apps, wallets and banks', () {
      for (final pkg in [
        'com.phonepe.app', // PhonePe
        'net.one97.paytm', // Paytm
        'com.google.android.apps.nbu.paisa.user', // Google Pay
        'in.org.npci.upiapp', // BHIM
        'com.dreamplug.androidapp', // CRED
        'com.sbi.lotusintouch', // SBI YONO
        'com.snapwork.hdfc', // HDFC
        'com.csam.icici.bank.imobile', // ICICI
        'com.axis.mobile', // Axis
        'com.msf.kbank.mobile', // Kotak
        'com.bankofbaroda.mconnect', // Bank of Baroda
      ]) {
        expect(sensitive(pkg), isTrue, reason: pkg);
      }
    });

    test('global wallets, banks and crypto', () {
      for (final pkg in [
        'com.paypal.android.p2pmobile',
        'com.squareup.cash',
        'com.revolut.revolut',
        'co.uk.getmondo',
        'com.google.android.apps.walletnfcrel',
        'com.coinbase.android',
        'com.paypal.android.p2pmobile:remote',
      ]) {
        expect(sensitive(pkg), isTrue, reason: pkg);
      }
    });

    test('unlisted apps are caught by package signal', () {
      for (final pkg in [
        'com.examplebank.mobile',
        'in.co.somebank.netbanking',
        'com.acme.wallet',
        'com.acme.upi',
        'com.acme.gpay',
      ]) {
        expect(sensitive(pkg), isTrue, reason: pkg);
      }
    });

    test('ordinary apps are not blocked', () {
      for (final pkg in [
        'com.example.notes',
        'com.whatsapp',
        'com.google.android.youtube',
        'com.android.chrome',
        'com.google.android.gm',
        'com.google.android.apps.maps',
        'com.spotify.music',
        'com.android.settings',
        'com.dhanuk.ovidai',
        'com.samsung.android.display',
      ]) {
        expect(sensitive(pkg), isFalse, reason: pkg);
      }
    });

    test('banking sites by domain and by bank label', () {
      for (final url in [
        'https://www.onlinesbi.sbi/login',
        'https://netbanking.hdfcbank.com/netbanking/',
        'https://www.paytm.com/',
        'https://ibank.example.co.uk/',
        'https://payments.wise.com/send',
      ]) {
        expect(
          DeviceControlService.isSensitiveTargetForTest(url: url),
          isTrue,
          reason: url,
        );
      }
      expect(
        DeviceControlService.isSensitiveTargetForTest(
          url: 'https://en.wikipedia.org/wiki/UPI',
        ),
        isFalse,
      );
    });

    test('disclosure matches what is enforced', () {
      expect(kControlModeDisclosure, contains('banking or payment screens'));
      expect(kControlModeDisclosure, contains('PhonePe'));
      expect(kControlModeDisclosure, contains('UPI PIN'));
      expect(kControlModeDisclosure, contains('cannot cover every app'));
    });
  });

  group('payment step inside an unlisted app', () {
    test(
      'withholds the screen and refuses actions until a clean full read',
      () async {
        readPackage = 'com.example.shop';
        probeAnswer = {'package': 'com.example.shop'};
        screenText = 'Enter UPI PIN';
        var out = await AgentService.I.dispatchForTest('device_read', {});
        expect(out, contains('DENIED'));
        expect(out, isNot(contains('Enter UPI PIN')));

        out = await AgentService.I.dispatchForTest('device_tap', {
          'x': 10,
          'y': 10,
        });
        expect(out, contains('DENIED'));
        expect(calls.where((c) => c.method == 'deviceTap'), isEmpty);

        // A delta read without the marker does not clear the flag ...
        screenText = 'Order summary';
        await AgentService.I.dispatchForTest('device_read', {});
        out = await AgentService.I.dispatchForTest('device_tap', {
          'x': 10,
          'y': 10,
        });
        expect(out, contains('DENIED'));

        // ... a clean FULL read does.
        readFull = true;
        out = await AgentService.I.dispatchForTest('device_read', {
          'mode': 'full',
        });
        expect(out, contains('Order summary'));
        out = await AgentService.I.dispatchForTest('device_tap', {
          'x': 10,
          'y': 10,
        });
        expect(out, isNot(contains('DENIED')));
      },
    );

    test('card form markers are detected', () {
      expect(
        DeviceControlService.looksLikePaymentScreen('[3] EditText "CVV"'),
        isTrue,
      );
      expect(
        DeviceControlService.looksLikePaymentScreen('[3] Text "Inbox"'),
        isFalse,
      );
    });
  });
}
