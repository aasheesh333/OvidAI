import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/device_control_service.dart';

// Icon knowledge for guiding taps: rows with empty text/desc gain an
// inferred `icon="<role>"` tag from class/viewId keywords, refined by a
// per-app map. The agent uses handle + icon label + bounds to tap and to
// describe steps to the user ("tap the paper-plane Send icon").
void main() {
  Map<String, dynamic> readResult(
    List<Map<String, dynamic>> added, {
    String package = '',
  }) => {
    'status': 'ok',
    'package': package,
    'added': added,
    'changed': [],
    'removed': [],
  };

  Map<String, dynamic> iconButton({
    required int handle,
    String viewId = '',
    String text = '',
    String description = '',
  }) => {
    'handle': handle,
    'class': 'android.widget.ImageButton',
    'text': text,
    'description': description,
    'viewId': viewId,
    'bounds': const [100, 200, 148, 248],
    'clickable': true,
  };

  test('empty ImageButton gains an inferred icon role from viewId', () {
    final out = DeviceControlService.formatReadResultForTest(
      readResult([
        iconButton(handle: 7, viewId: 'com.example:id/share_button'),
      ]),
    );
    expect(out, contains('[7]'));
    expect(out, contains('icon="share"'));
  });

  test('inferred role never hides existing text or description', () {
    final out = DeviceControlService.formatReadResultForTest(
      readResult([
        iconButton(
          handle: 3,
          viewId: 'com.example:id/send_btn',
          description: 'Send message',
        ),
      ]),
    );
    expect(out, contains('desc="Send message"'));
    expect(out, contains('icon="send"'));
  });

  test('plain text nodes gain no icon tag', () {
    final out = DeviceControlService.formatReadResultForTest(
      readResult([
        {
          'handle': 1,
          'class': 'android.widget.TextView',
          'text': 'Hello world',
          'description': '',
          'viewId': '',
          'bounds': const [0, 0, 100, 40],
        },
      ]),
    );
    expect(out, contains('"Hello world"'));
    expect(out.contains('icon='), isFalse);
  });

  test('per-app map refines generic keywords for known packages', () {
    const row = {
      'handle': 9,
      'class': 'android.widget.ImageView',
      'text': '',
      'description': 'Direct',
      'viewId': 'com.instagram.android:id/direct_button',
      'bounds': [900, 100, 960, 160],
      'clickable': true,
    };
    final scoped = DeviceControlService.formatReadResultForTest(
      readResult([row], package: 'com.instagram.android'),
    );
    expect(scoped, contains('icon="direct inbox"'));

    final unscoped = DeviceControlService.formatReadResultForTest(
      readResult([row], package: 'com.example.other'),
    );
    expect(unscoped.contains('icon="direct inbox"'), isFalse);
  });

  test('icon lookup is exposed for tests with package scoping', () {
    expect(
      DeviceControlService.iconRoleForTest(
        packageName: 'com.instagram.android',
        className: 'android.widget.ImageView',
        text: '',
        description: '',
        viewId: 'row_feed_button_like',
      ),
      'like button',
    );
    expect(
      DeviceControlService.iconRoleForTest(
        packageName: 'com.example.other',
        className: 'android.widget.ImageButton',
        text: '',
        description: '',
        viewId: 'action_search_view',
      ),
      'search',
    );
    expect(
      DeviceControlService.iconRoleForTest(
        packageName: 'com.example.other',
        className: 'android.widget.TextView',
        text: 'plain label',
        description: '',
        viewId: '',
      ),
      isNull,
    );
  });

  test('device_read tool description documents icon labels for guiding', () {
    final src = File('lib/core/agent_service.dart').readAsStringSync();
    final idx = src.indexOf("'name': 'device_read'");
    expect(idx, greaterThanOrEqualTo(0));
    final body = src.substring(idx, idx + 1200);
    expect(body, contains('icon'));
    expect(body, contains('device_tap'));
  });
}
