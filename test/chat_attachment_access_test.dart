// Chat attachments live in app-private storage on Android
// (`/data/user/0/<pkg>/files/workspaces/ws_<id>/.attachments/<sid>/…`). The
// self-source gate used to refuse every absolute path under the install root
// except `files/sessions/`, so the image tools could not read anything the
// user attached ("stored in a protected app path"). These tests lay out a fake
// install root and pin the boundary: the chat's own attachments and image
// outputs are readable; other chats' uploads and the rest of app-private
// storage are not, symlinks included.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'image_studio_test.dart' show picture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late String install;
  late String files;
  late ChatSession a;
  late ChatSession b;
  late ChatSession shared;
  late File pickedSource;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('attach-access-');
    tmp = Directory(await tmp.resolveSymbolicLinks());
    install = '${tmp.path}/data/user/0/com.dhanuk.ovidai';
    files = '$install/files';
    await Directory(files).create(recursive: true);
    SandboxService.filesRootOverrideForTest = Directory(files);
    AgentService.installRootsOverrideForTest = [install];
    SessionLedger.rootOverrideForTest = await Directory(
      '${tmp.path}/ledger',
    ).create();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    a = ChatSession(id: 'chat-a', title: 'A', model: 'test', mode: 'auto');
    b = ChatSession(id: 'chat-b', title: 'B', model: 'test', mode: 'auto');
    // Shares chat A's workspace on purpose (explicitly shared sandbox).
    shared = ChatSession(id: 'chat-c', title: 'C', model: 'test', mode: 'auto')
      ..sandboxId = 'chat-a';
    app.sessions.addAll([a, b, shared]);
    app.activeSessionId = a.id;
    AgentService.setRunSessionForTest(a.id);
    AgentService.I.debugPauseScheduleTimerForTest(true);
    // The picker hands over a file from outside the app (gallery cache).
    pickedSource = File('${tmp.path}/gallery/photo.png');
    await pickedSource.parent.create(recursive: true);
    await pickedSource.writeAsBytes(await picture());
  });

  tearDown(() async {
    for (final s in [a, b, shared]) {
      await SessionLedger.I.close(s.id);
    }
    SessionLedger.rootOverrideForTest = null;
    SandboxService.filesRootOverrideForTest = null;
    AgentService.installRootsOverrideForTest = null;
    AgentService.setRunSessionForTest('');
    AgentService.I.pendingAttachments.clear();
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
    await tmp.delete(recursive: true);
  });

  Future<String> attach(ChatSession s, String name) async {
    final err = await AgentService.I.attachFile(
      pickedSource.path,
      name,
      sessionId: s.id,
    );
    expect(err, isNull);
    final staged = AgentService.I.pendingAttachmentsForTest(s.id);
    return staged.lastWhere((x) => x.name == name).path;
  }

  Future<String> resize(String path) => AgentService.I.dispatchForTest(
    'resize_image',
    {'path': path, 'width': 4, 'height': 3},
  );

  Future<String> editWith({
    required String path,
    List<String> references = const [],
    String? mask,
  }) => AgentService.I.dispatchForTest('edit_image', {
    'prompt': 'remove the text',
    'size': '1024x1024',
    'request_id': 'req-1',
    'path': path,
    if (references.isNotEmpty) 'reference_paths': references,
    'mask_path': ?mask,
  });

  List<Message> images(ChatSession s) =>
      s.messages.where((m) => m.kind == MsgKind.imageGen).toList();

  test('attachment is stored per chat in persistent app storage, and the '
      'prompt note carries the exact path the tools accept', () async {
    final path = await attach(a, 'photo.png');
    expect(
      path,
      startsWith('$files/workspaces/ws_chat-a/.attachments/chat-a/upload-'),
    );
    // Not the purgeable cache/tmp dir: the support dir survives restarts.
    expect(path, isNot(contains('/cache/')));
    final note = AgentService.I.attachmentContextForTest([
      MessageAttachment(name: 'photo.png', size: 1, path: path),
    ]);
    expect(note, contains('"$path"'));
    expect(note, contains('reference_paths'));
    expect(await resize(path), startsWith('Image saved:'));
  });

  test('resize/crop/edit (path, reference_paths, mask_path) read the chat\'s '
      'own attachment by the exact absolute path', () async {
    final path = await attach(a, 'photo.png');
    final ref = await attach(a, 'ref.png');
    final resized = await resize(path);
    expect(resized, startsWith('Image saved:'));
    final cropped = await AgentService.I.dispatchForTest('crop_image', {
      'path': path,
      'x': 0,
      'y': 0,
      'width': 2,
      'height': 2,
    });
    expect(cropped, startsWith('Image saved:'));
    // The inference tools read every input before the cloud call; with no
    // cloud key the call stops at sign-in, which proves all inputs passed the
    // path gates (a refusal returns ACCESS_DENIED first).
    final edited = await editWith(path: path, references: [ref], mask: ref);
    expect(edited, isNot(contains('ACCESS_DENIED')));
    expect(edited, contains('sign in to Ovid Cloud'));
    expect(AgentService.I.pendingApproval, isNull);
    // Read tools accept the same path.
    final read = await AgentService.I.dispatchForTest('file_read', {
      'path': path,
    });
    expect(read, isNot(contains('ACCESS_DENIED')));
  });

  test('edited/generated output is shown in chat and readable by a follow-up '
      'call via both the absolute and workspace path', () async {
    final path = await attach(a, 'photo.png');
    final first = await resize(path);
    expect(first, startsWith('Image saved:'));
    final shown = images(a).single;
    expect(first, contains(shown.imagePath!));
    expect(await File(shown.imagePath!).exists(), isTrue);
    expect(shown.imagePath, startsWith('$files/workspaces/ws_chat-a/'));
    final relative = RegExp(
      r'workspace path: `([^`]+)`',
    ).firstMatch(first)!.group(1)!;
    expect(await resize(shown.imagePath!), startsWith('Image saved:'));
    expect(await resize(relative), startsWith('Image saved:'));
    expect(images(a), hasLength(3));
    final last = await File(images(a).last.imagePath!).readAsBytes();
    expect((await ImageStudio.inspect(last)).width, 4);
  });

  test('another chat\'s attachment is refused, including in a shared '
      'workspace and as reference_paths', () async {
    final mine = await attach(a, 'photo.png');
    final otherWorkspace = await attach(b, 'photo.png');
    final sameWorkspace = await attach(shared, 'photo.png');
    expect(
      sameWorkspace,
      startsWith('$files/workspaces/ws_chat-a/.attachments/chat-c/'),
    );
    final relativeSame = sameWorkspace.substring(
      '$files/workspaces/ws_chat-a/'.length,
    );
    for (final foreign in [otherWorkspace, sameWorkspace, relativeSame]) {
      final out = await resize(foreign);
      expect(out, contains('ACCESS_DENIED'), reason: foreign);
      expect(out, isNot(contains('re-upload the')), reason: foreign);
      expect(AgentService.I.pendingApproval, isNull, reason: foreign);
    }
    expect(await resize(sameWorkspace), contains('different chat'));
    expect(await resize(relativeSame), contains('different chat'));
    final edit = await editWith(path: mine, references: [sameWorkspace]);
    expect(edit, contains('different chat'));
    expect(images(a), isEmpty);
    // Chat B can still use its own upload.
    AgentService.setRunSessionForTest(b.id);
    expect(await resize(otherWorkspace), startsWith('Image saved:'));
  });

  test('app-private storage stays refused in every mode without a prompt, '
      'and the refusal tells the model to use the attachment path', () async {
    Future<String> plant(String rel) async {
      final f = File('$install/$rel');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(await picture());
      return f.path;
    }

    final private = [
      await plant('shared_prefs/FlutterSharedPreferences.xml'),
      await plant('shared_prefs/FlutterSecureStorage.xml'),
      await plant('databases/ovid.db'),
      await plant('no_backup/creds.png'),
      await plant('code_cache/x.png'),
      await plant('app_flutter/sessions.json'),
      await plant('files/workspaces/ws_chat-b/secret.png'),
      await plant('files/.ovid-git-credentials'),
    ];
    for (final mode in ['auto', 'drive', 'control', 'studio']) {
      a.mode = mode;
      for (final p in private) {
        for (final call in [
          ('resize_image', {'path': p, 'width': 2, 'height': 2}),
          ('file_read', {'path': p}),
          (
            'edit_image',
            {'prompt': 'x', 'size': '1024x1024', 'request_id': 'r', 'path': p},
          ),
          ('run_shell', {'command': 'cat $p'}),
        ]) {
          final out = await AgentService.I.dispatchForTest(call.$1, call.$2);
          expect(out, contains('ACCESS_DENIED'), reason: '$mode ${call.$1} $p');
          expect(out, contains('private app storage'), reason: '$mode $p');
          expect(out, contains('exact paths'), reason: '$mode $p');
          expect(out, isNot(contains('separate project')));
          expect(AgentService.I.pendingApproval, isNull);
        }
      }
      // reference_paths / mask_path are gated too.
      final mine = await attach(a, 'photo.png');
      for (final key in ['reference_paths', 'mask_path']) {
        final out = await AgentService.I.dispatchForTest('edit_image', {
          'prompt': 'x',
          'size': '1024x1024',
          'request_id': 'r',
          'path': mine,
          key: key == 'mask_path' ? private.first : [private.first],
        });
        expect(out, contains('private app storage'), reason: '$mode $key');
      }
    }
    expect(images(a), isEmpty);
  });

  test('a symlink from the attachment folder to a private file is refused, '
      'by absolute and relative path', () async {
    final prefs = File('$install/shared_prefs/FlutterSecureStorage.xml');
    await prefs.parent.create(recursive: true);
    await prefs.writeAsBytes(await picture());
    final mine = await attach(a, 'photo.png');
    final link = Link('${File(mine).parent.path}/innocent.png');
    await link.create(prefs.path);
    final relative = link.path.substring('$files/workspaces/ws_chat-a/'.length);
    // A symlinked attachment directory that points at another chat's upload.
    final theirs = await attach(b, 'photo.png');
    final dirLink = Link(
      '$files/workspaces/ws_chat-a/.attachments/chat-a/borrowed',
    );
    await dirLink.create(File(theirs).parent.path);
    for (final mode in ['auto', 'drive']) {
      a.mode = mode;
      for (final p in [link.path, relative, '${dirLink.path}/photo.png']) {
        final out = await resize(p);
        expect(out, contains('ACCESS_DENIED'), reason: '$mode $p');
        expect(AgentService.I.pendingApproval, isNull, reason: '$mode $p');
        final edit = await editWith(path: mine, references: [p]);
        expect(edit, contains('ACCESS_DENIED'), reason: '$mode ref $p');
      }
    }
    expect(images(a), isEmpty);
  });
}
