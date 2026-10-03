import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'image_studio_test.dart' show picture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory work;
  late ChatSession session;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('image-tools-');
    work = await Directory('${root.path}/work').create();
    SessionLedger.rootOverrideForTest = await Directory(
      '${root.path}/ledger',
    ).create();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    session = ChatSession(
      id: 'images',
      title: 'Images',
      model: 'test',
      mode: 'auto',
    )..workspaceFolder = work.path;
    app.sessions.add(session);
    app.activeSessionId = session.id;
    AgentService.setRunSessionForTest(session.id);
    AgentService.I.debugPauseScheduleTimerForTest(true);
  });

  tearDown(() async {
    await SessionLedger.I.close(session.id);
    SessionLedger.rootOverrideForTest = null;
    AgentService.setRunSessionForTest('');
    AgentService.I.pendingAttachments.clear();
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
    await root.delete(recursive: true);
  });

  test(
    'exact nested source produces saved displayed PNG and source is preserved',
    () async {
      final source = File('${work.path}/nested/source.png');
      await source.parent.create();
      final original = await picture();
      await source.writeAsBytes(original);
      final result = await AgentService.I.dispatchForTest('resize_image', {
        'path': 'nested/source.png',
        'width': 4,
        'height': 3,
      });
      expect(result, startsWith('Image saved:'));
      final message = session.messages.singleWhere(
        (m) => m.kind == MsgKind.imageGen,
      );
      expect(result, contains(message.imagePath!));
      expect(await File(message.imagePath!).exists(), isTrue);
      expect(
        (await ImageStudio.inspect(
          await File(message.imagePath!).readAsBytes(),
        )).width,
        4,
      );
      expect(await source.readAsBytes(), original);
    },
  );

  test(
    'outside symlink and relative traversal both use the path grant gate',
    () async {
      final source = File('${root.path}/private.png');
      await source.writeAsBytes(await picture());
      await Link('${work.path}/escape.png').create(source.path);
      for (final path in ['escape.png', '../private.png']) {
        final future = AgentService.I.dispatchForTest('crop_image', {
          'path': path,
          'x': 0,
          'y': 0,
          'width': 2,
          'height': 2,
        });
        if (path == '../private.png') {
          // A denial persists for the canonical target across path spellings.
          expect(await future, contains('ACCESS_DENIED'));
          expect(AgentService.I.pendingApproval, isNull);
          continue;
        }
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (AgentService.I.pendingApproval == null &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final approval = AgentService.I.pendingApproval;
        expect(approval, isNotNull);
        expect(approval!.tool, contains('grant:path:'));
        AgentService.I.approve(false);
        expect(await future, contains('ACCESS_DENIED'));
      }
      expect(
        session.messages.where((m) => m.kind == MsgKind.imageGen),
        isEmpty,
      );
    },
  );

  test(
    'staging rejects path injection and keeps collision-resolved exact paths',
    () async {
      final source = File('${root.path}/source.png');
      await source.writeAsBytes(await picture());
      expect(
        await AgentService.I.attachFile(source.path, '../escape.png'),
        isNotNull,
      );
      expect(await AgentService.I.attachFile(source.path, 'input.png'), isNull);
      expect(await AgentService.I.attachFile(source.path, 'input.png'), isNull);
      final staged = AgentService.I.pendingAttachments;
      expect(staged.map((a) => a.name), ['input.png', 'input.png']);
      expect(staged.map((a) => a.path).toSet(), hasLength(2));
      for (final attachment in staged) {
        expect(attachment.path, startsWith('${work.path}/.attachments/'));
        expect(await File(attachment.path).readAsBytes(), await source.readAsBytes());
      }
      final resized = await AgentService.I.dispatchForTest('resize_image', {
        'path': staged.last.path, 'width': 3, 'height': 2,
      });
      expect(resized, startsWith('Image saved:'));
    },
  );

  test(
    'read-only mode blocks every image-writing tool before file or network access',
    () async {
      session.mode = 'safe';
      for (final tool in [
        'generate_image',
        'edit_image',
        'resize_image',
        'crop_image',
      ]) {
        final result = await AgentService.I.dispatchForTest(tool, {});
        expect(result, startsWith('READ-ONLY MODE:'), reason: tool);
      }
    },
  );
}
