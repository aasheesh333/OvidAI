import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Who CHOSE a session's working folder.
///
/// A brand-new chat inherits the previous folder on purpose (spec §5.2 — a
/// restart must not force a fresh selection). What was NOT on purpose is the
/// system prompt telling the model "the user pinned this chat to the folder
/// above" about a folder nobody picked in that chat: the model then announced
/// a repo and location the owner had never selected there, stated as fact.
/// Inheritance stays; the false claim about its provenance does not.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
  });

  tearDown(AppState.resetTestInstance);

  Directory tempFolder(String prefix) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    return dir;
  }

  group('provenance flag', () {
    test('an inherited folder is NOT pinned', () {
      final dir = tempFolder('ovid-prov-inherit');
      final app = AppState.createForTest();
      app.lastRepoFull = 'owner/repo';
      app.lastWorkspaceFolder = dir.path;

      app.newSession();

      final s = app.activeSession!;
      // The inheritance itself is preserved…
      expect(s.workspaceFolder, dir.path);
      // …but nobody chose it for this chat, so it must not claim they did.
      expect(s.workspaceFolderPinned, isFalse);
    });

    test('clearing the folder also clears the claim', () {
      final dir = tempFolder('ovid-prov-clear');
      final app = AppState.createForTest();

      app.setSessionWorkspaceFolder(dir.path);
      expect(app.activeSession!.workspaceFolderPinned, isTrue);

      app.setSessionWorkspaceFolder(null);
      expect(app.activeSession!.workspaceFolder, isNull);
      expect(app.activeSession!.workspaceFolderPinned, isFalse);
    });

    test('a session that never got a folder is not pinned either', () {
      final app = AppState.createForTest();
      app.newSession();
      expect(app.activeSession!.workspaceFolder, isNull);
      expect(app.activeSession!.workspaceFolderPinned, isFalse);
    });

    test('the flag survives a JSON round-trip', () {
      final dir = tempFolder('ovid-prov-json');
      final s = ChatSession(
        id: 'pinned',
        title: 't',
        model: 'm',
        workspaceFolder: dir.path,
        workspaceFolderPinned: true,
      );
      final restored = ChatSession.fromJson(s.toJson());
      expect(restored.workspaceFolder, dir.path);
      expect(restored.workspaceFolderPinned, isTrue);

      // Sessions written before the flag existed default to "not claimed" —
      // the prompt then under-claims rather than over-claims.
      final legacy = ChatSession.fromJson({
        'id': 'legacy',
        'title': 't',
        'model': 'm',
        'workspaceFolder': dir.path,
      });
      expect(legacy.workspaceFolderPinned, isFalse);
    });

    test('a forked chat carries the provenance across with the folder', () {
      final dir = tempFolder('ovid-prov-fork');
      final app = AppState.createForTest();
      app.setSessionWorkspaceFolder(dir.path);
      expect(app.activeSession!.workspaceFolderPinned, isTrue);
      final pinnedId = app.activeSession!.id;

      app.newSession();
      expect(app.activeSession!.workspaceFolderPinned, isFalse);

      app.setSessionWorkspaceFolder(dir.path, sessionId: pinnedId);
      final pinned = app.sessionById(pinnedId)!;
      expect(pinned.workspaceFolderPinned, isTrue);
      expect(pinned.workspaceFolder, dir.path);
    });
  });

  group('the system prompt tells the truth about who chose the folder', () {
    final src = File('lib/core/agent_service.dart').readAsStringSync();

    test('the "the user pinned this chat" branch is gated on the flag', () {
      // The false claim must only be reachable when the flag is set.
      expect(src, contains(': s.workspaceFolderPinned ?'));
      expect(src, contains('The user pinned this chat to the folder above'));
    });

    test('an inherited folder gets honest wording instead', () {
      expect(src, contains('Working folder (inherited):'));
      expect(
        src,
        contains('it was NOT\nchosen for this chat'),
      );
      expect(src, contains('do not announce this location'));
      expect(src, contains('do\nnot claim the user selected it'));
      expect(
        src,
        contains('do not present yourself as working in a\nparticular repo'),
      );
      // The folder still governs file work — provenance honesty must not
      // quietly weaken the sandbox rule.
      expect(
        src,
        contains('It is still where all\nfile work happens'),
      );
    });

    test('the inherited branch asks instead of assuming', () {
      expect(
        src,
        contains('ask the\nuser which one instead of assuming this one'),
      );
    });
  });
}
