import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/state.dart';

/// CH-026 / CT-019 (P0, data loss): "Reset all data" and chat delete called
/// the default workspace deleter, which resolved a session's PINNED
/// `workspaceFolder` (a folder the user picked on shared storage) and deleted
/// it recursively. The deleter may only ever touch the app-owned scratch dir.
void main() {
  test('the default deleter never follows a pinned user folder', () async {
    final userFolder = await Directory.systemTemp.createTemp('ovid-user-pick-');
    final keep = File('${userFolder.path}/thesis.md')..writeAsStringSync('mine');
    final previous = AppState.workspaceDirProvider;
    // The pinned-folder resolver that used to redirect the delete.
    AppState.workspaceDirProvider = (_) => userFolder;
    try {
      await deleteLocalScratchWorkspace('sess-pinned');

      expect(userFolder.existsSync(), isTrue,
          reason: 'a folder the user picked outside the app must survive');
      expect(keep.readAsStringSync(), 'mine');
    } finally {
      AppState.workspaceDirProvider = previous;
      await userFolder.delete(recursive: true);
    }
  });

  test('the app-owned scratch dir is still deleted', () async {
    final scratch = Directory(
        '${Directory.systemTemp.path}/ovid_workspaces/sess-scratch-test');
    await scratch.create(recursive: true);
    File('${scratch.path}/tmp.txt').writeAsStringSync('x');

    await deleteLocalScratchWorkspace('sess-scratch-test');

    expect(scratch.existsSync(), isFalse);
  });

  test('a symlink planted at the scratch path is unlinked, its target kept',
      () async {
    final target = await Directory.systemTemp.createTemp('ovid-link-target-');
    final keep = File('${target.path}/keep.txt')..writeAsStringSync('keep');
    final root = Directory('${Directory.systemTemp.path}/ovid_workspaces');
    await root.create(recursive: true);
    final link = Link('${root.path}/sess-link-test');
    if (link.existsSync()) await link.delete();
    await link.create(target.path);
    try {
      await deleteLocalScratchWorkspace('sess-link-test');

      expect(link.existsSync(), isFalse);
      expect(keep.readAsStringSync(), 'keep');
    } finally {
      await target.delete(recursive: true);
    }
  });

  test('path-like ids cannot escape the scratch root', () async {
    final outside = await Directory.systemTemp.createTemp('ovid-escape-');
    try {
      await deleteLocalScratchWorkspace('../${outside.path.split('/').last}');
      await deleteLocalScratchWorkspace('..');
      expect(outside.existsSync(), isTrue);
    } finally {
      await outside.delete(recursive: true);
    }
  });
}
