import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_backup.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/settings_backup_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Rest extends CloudRestClient {
  _Rest() : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  CloudApiException? failWith;
  final List<SessionDto> sessions = [
    for (var i = 0; i < 2; i++)
      SessionDto(
        id: 'aaaaaaaa-0000-7000-8000-00000000000$i',
        title: 'Chat $i',
        mode: 'auto',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
  ];

  @override
  Future<CloudPage<SessionDto>> listSessions({
    int limit = 50,
    String? cursor,
  }) async {
    if (failWith != null) throw failWith!;
    return CloudPage(items: sessions, nextCursor: null);
  }

  @override
  Future<CloudPage<MessageDto>> pageMessages(
    String sessionId, {
    int limit = 50,
    String? before,
  }) async => CloudPage(
    items: [
      for (var i = 0; i < 3; i++)
        MessageDto(
          id: '$sessionId-$i',
          sessionId: sessionId,
          role: i.isEven ? 'user' : 'assistant',
          content: 'm$i',
          createdAt: DateTime.utc(2026, 1, 1, 0, 3 - i),
        ),
    ],
    nextCursor: null,
  );
}

void main() {
  late _Rest rest;
  late Directory temp;

  setUp(() async {
    AppState.resetTestInstance();
    AppState.createForTest();
    SharedPreferences.setMockInitialValues({});
    rest = _Rest();
    temp = await Directory.systemTemp.createTemp('backup-screen-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => temp.path,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('ovid/native'),
          (_) async => true,
        );
  });

  tearDown(() async {
    AppState.resetTestInstance();
    for (final channel in ['plugins.flutter.io/path_provider', 'ovid/native']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), null);
    }
    await temp.delete(recursive: true);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: SettingsBackupScreen(backup: CloudBackup(rest: rest))),
    );
    await tester.pump();
  }

  testWidgets('one consistent "Export & import" name and Aether background', (
    tester,
  ) async {
    await pumpScreen(tester);

    // App bar title + section eyebrow (upper-cased by the primitive).
    expect(find.text('Export & import'), findsOneWidget);
    expect(find.text('EXPORT & IMPORT'), findsOneWidget);
    expect(find.text('Export data'), findsNothing);
    expect(find.text('BACKUP'), findsNothing);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      Aether.bg,
    );
    expect(find.text('Export-ready archive'), findsOneWidget);
    expect(find.text('Share archive'), findsOneWidget);
    expect(find.textContaining('Share / save'), findsOneWidget);
  });

  testWidgets('copy promises cloud upload, not local inactive chats', (
    tester,
  ) async {
    await pumpScreen(tester);

    expect(
      find.bySemanticsLabel('Export & import status: Ready to export'),
      findsOneWidget,
    );
    expect(find.textContaining('Ovid Cloud account'), findsWidgets);
    expect(find.textContaining('keep their context'), findsOneWidget);
    // SE-008 / SE-021: no retired workspace, sandbox, plugin or MCP claims.
    for (final stale in [
      'inactive',
      'approved app workspace roots',
      'sandbox',
      'plugin',
      'MCP',
      'portable attachment',
    ]) {
      expect(find.textContaining(stale), findsNothing, reason: stale);
    }
  });

  testWidgets('export reports chats and messages fetched from the server', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.runAsync(() async {
      await tester.tap(find.text('Export'));
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find.textContaining('Exported').evaluate().isNotEmpty) break;
      }
    });
    await tester.pump();
    expect(find.textContaining('Exported 2 chats · 6 messages.'), findsOneWidget);
  });

  testWidgets('signed out export fails with a human message', (tester) async {
    rest.failWith = CloudApiException(
      status: 401,
      code: 'unauthenticated',
      message: 'Sign in to use Ovid Cloud.',
    );
    await pumpScreen(tester);
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect(find.textContaining(CloudBackupCopy.signInRequired), findsOneWidget);
    expect(find.textContaining('No data was changed'), findsOneWidget);
    expect(find.textContaining('CloudApiException'), findsNothing);
  });
}
