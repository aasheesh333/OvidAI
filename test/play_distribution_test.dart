import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/distribution.dart';
import 'package:ovid_ai/core/sandbox_service.dart';

/// Google Play build gates (docs/play/PLAY_COMPLIANCE_AUDIT.md).
void main() {
  tearDown(() => Distribution.playOverrideForTest = null);

  test('sideload builds keep every capability', () {
    Distribution.playOverrideForTest = false;
    expect(Distribution.controlModeAvailable, isTrue);
    expect(Distribution.onDeviceSandboxAvailable, isTrue);
    expect(Distribution.idleKeepAliveAvailable, isTrue);
    expect(modeOptionsForPicker(), contains(AgentMode.control));
    expect(Distribution.agentPermissions, Distribution.allAgentPermissions);
    expect(sandboxPreflightGate(sdkInt: 34, dataExecAllowed: true), isNull);
  });

  test('Play builds drop Control mode, the sandbox and idle keep-alive', () {
    Distribution.playOverrideForTest = true;
    expect(Distribution.controlModeAvailable, isFalse);
    expect(Distribution.onDeviceSandboxAvailable, isFalse);
    expect(Distribution.idleKeepAliveAvailable, isFalse);
    expect(modeOptionsForPicker(), isNot(contains(AgentMode.control)));
    expect(modeOptionsForPicker(), contains(AgentMode.auto));
  });

  test('Play preflight refuses the sandbox before any payload or download', () {
    final gate = sandboxPreflightGate(
      sdkInt: 36,
      dataExecAllowed: true,
      onDeviceSandboxAvailable: false,
    );
    expect(gate, isA<SandboxUnsupportedException>());
    expect(gate!.message, Distribution.sandboxUnavailableMessage);
  });

  test('Play agent permissions match the Play manifest', () {
    Distribution.playOverrideForTest = true;
    expect(
      Distribution.agentPermissions,
      unorderedEquals(['notifications', 'camera', 'microphone', 'location']),
    );
    for (final removed in ['sms', 'phone', 'contacts', 'calendar', 'sensors']) {
      expect(Distribution.agentPermissions, isNot(contains(removed)));
    }
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
      expect(
        gradle,
        contains('if (ovidPlayBuild) excludes += "**/libovid_bootstrap.so"'),
      );
      expect(
        gradle,
        contains('addStaticManifestFile("src/play/AndroidManifest.xml")'),
      );
    });

    test('the overlay removes the AccessibilityService and risky permissions', () {
      expect(
        overlay,
        matches(
          RegExp(
            r'android:name="com\.dhanuk\.ovidai\.OvidAccessibilityService"\s+tools:node="remove"',
          ),
        ),
      );
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
        'android.permission.FOREGROUND_SERVICE_SPECIAL_USE',
        'com.google.android.gms.permission.AD_ID',
      ]) {
        expect(
          overlay,
          contains('<uses-permission android:name="$permission" tools:node="remove" />'),
          reason: permission,
        );
      }
      expect(overlay, contains('android:foregroundServiceType="dataSync"'));
      // XML comments may not contain a double hyphen; the merger rejects it.
      final comments = RegExp(r'<!--([\s\S]*?)-->').allMatches(overlay);
      for (final c in comments) {
        expect(c.group(1)!.contains('--'), isFalse);
      }
    });

    test('dataSync services stop when Android 15 exhausts the FGS budget', () {
      final service = File(
        'android/app/src/main/kotlin/com/dhanuk/ovidai/AgentForegroundService.kt',
      ).readAsStringSync();
      expect(service, contains('override fun onTimeout(startId: Int, fgsType: Int)'));
    });
  });
}
