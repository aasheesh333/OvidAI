import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/distribution.dart';

/// Google Play build gates (docs/play/PLAY_COMPLIANCE_AUDIT.md).
void main() {
  tearDown(() => Distribution.playOverrideForTest = null);

  test('Control mode and the on-device sandbox are gone on every channel', () {
    for (final play in [false, true]) {
      Distribution.playOverrideForTest = play;
      expect(Distribution.controlModeAvailable, isFalse);
      expect(Distribution.onDeviceSandboxAvailable, isFalse);
      expect(AgentMode.values.map((m) => m.name), isNot(contains('control')));
      expect(modeOptionsForPicker(), contains(AgentMode.auto));
    }
  });

  test('the declared permission set matches the manifest exactly', () {
    // The on-device agent is gone (P8 Tasks 12/13/16), so the manifest must
    // not keep requesting permissions nothing uses — Play rejects or demands
    // justification for broad ones (SEND_SMS, MANAGE_EXTERNAL_STORAGE).
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final declared = RegExp(r'android\.permission\.([A-Z_]+)')
        .allMatches(manifest)
        .map((m) => m.group(1)!)
        .toSet();
    expect(declared, {'INTERNET', 'POST_NOTIFICATIONS', 'RECORD_AUDIO'});
    for (final removed in [
      'SEND_SMS',
      'CALL_PHONE',
      'READ_CONTACTS',
      'WRITE_CONTACTS',
      'READ_CALENDAR',
      'WRITE_CALENDAR',
      'ACCESS_FINE_LOCATION',
      'ACCESS_COARSE_LOCATION',
      'MANAGE_EXTERNAL_STORAGE',
      'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
      'CAMERA',
      'BODY_SENSORS',
      'ACTIVITY_RECOGNITION',
      'BLUETOOTH_SCAN',
      'BLUETOOTH_CONNECT',
      'READ_PHONE_STATE',
    ]) {
      expect(manifest, isNot(contains(removed)), reason: removed);
    }
    expect(
      Distribution.declaredPermissions,
      unorderedEquals(['internet', 'notifications', 'microphone']),
    );
  });

  group('native Play packaging', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final overlay = File(
      'android/app/src/play/AndroidManifest.xml',
    ).readAsStringSync();

    test('the Dart define drives targetSdk 36 and drops the sandbox payload', () {
      expect(gradle, contains('"OVID_PLAY_BUILD=true"'));
      expect(gradle, contains('val ovidPlayTargetSdk = 36'));
      expect(
        gradle,
        contains(
          'targetSdk = if (ovidPlayBuild) ovidPlayTargetSdk else ovidSideloadTargetSdk',
        ),
      );
      // P8 Task 13 removed the bundled Termux userland from every build.
      expect(gradle, isNot(contains('libovid_bootstrap.so')));
      expect(
        gradle,
        contains('addStaticManifestFile("src/play/AndroidManifest.xml")'),
      );
    });

    test('the overlay removes risky permissions', () {
      for (final permission in [
        'android.permission.SEND_SMS',
        'android.permission.CALL_PHONE',
        'android.permission.READ_CONTACTS',
        'android.permission.READ_CALENDAR',
        'android.permission.BODY_SENSORS',
        'android.permission.READ_MEDIA_IMAGES',
        'android.permission.READ_MEDIA_VIDEO',
        'android.permission.MANAGE_EXTERNAL_STORAGE',
        'android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
        'com.google.android.gms.permission.AD_ID',
      ]) {
        expect(
          overlay,
          contains('<uses-permission android:name="$permission" tools:node="remove" />'),
          reason: permission,
        );
      }
      // XML comments may not contain a double hyphen; the merger rejects it.
      final comments = RegExp(r'<!--([\s\S]*?)-->').allMatches(overlay);
      for (final c in comments) {
        expect(c.group(1)!.contains('--'), isFalse);
      }
    });

  });
}
