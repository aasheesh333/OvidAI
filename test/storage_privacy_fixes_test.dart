import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/agent_service.dart';

/// Storage, privacy and duplicate-execution fixes (2026-09-24).
///
///  • Oversized tool output was spilled to `<workspace>/.spill/<ts>.txt` and
///    NEVER deleted — nothing pruned it anywhere in the codebase — so heavy use
///    accumulated hundreds of megabytes per workspace, permanently.
///  • `device_screenshot` copied the capture into the workspace but left the
///    native original in `cacheDir/device-captures`, so every Control run
///    accumulated full-screen PNGs OF OTHER APPS indefinitely, unencrypted.
///  • A tool timeout abandoned the future without cancelling the work AND told
///    the model to "narrow the request and retry", so it re-issued the same
///    command and two copies of a mutating operation ran concurrently against
///    the same workspace.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('spill-prune-');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('spill files are pruned', () {
    test('only the newest N survive', () {
      final spill = Directory('${dir.path}/.spill')..createSync(recursive: true);
      final total = maxSpillFilesPerWorkspace + 25;
      for (var i = 0; i < total; i++) {
        // Ids are millisecond timestamps, so lexical order == chronological.
        File('${spill.path}/${1700000000000 + i}.txt').writeAsStringSync('x$i');
      }
      expect(spill.listSync().length, total);

      pruneSpillDir(spill);

      final left = spill.listSync().whereType<File>().toList();
      expect(left.length, maxSpillFilesPerWorkspace);
      // The NEWEST must survive: recent messages still carry locator hints
      // (`sed -n`, `grep -n`) pointing at their spill path.
      expect(
        File('${spill.path}/${1700000000000 + total - 1}.txt').existsSync(),
        isTrue,
      );
      expect(
        File('${spill.path}/1700000000000.txt').existsSync(),
        isFalse,
        reason: 'the oldest spill should be the one dropped',
      );
    });

    test('pruning under the cap is a no-op', () {
      final spill = Directory('${dir.path}/.spill')..createSync(recursive: true);
      for (var i = 0; i < 3; i++) {
        File('${spill.path}/${1700000000000 + i}.txt').writeAsStringSync('x');
      }
      pruneSpillDir(spill);
      expect(spill.listSync().length, 3);
    });

    test('a missing directory does not throw', () {
      pruneSpillDir(Directory('${dir.path}/does-not-exist'));
    });

    test('non-spill files are left alone', () {
      final spill = Directory('${dir.path}/.spill')..createSync(recursive: true);
      File('${spill.path}/notes.md').writeAsStringSync('keep me');
      for (var i = 0; i < maxSpillFilesPerWorkspace + 5; i++) {
        File('${spill.path}/${1700000000000 + i}.txt').writeAsStringSync('x');
      }

      pruneSpillDir(spill);

      expect(File('${spill.path}/notes.md').existsSync(), isTrue);
      expect(
        spill.listSync().whereType<File>().where((f) => f.path.endsWith('.txt')).length,
        maxSpillFilesPerWorkspace,
      );
    });
  });

  group('the device-screenshot cache original is removed', () {
    test('the workspace copy is kept and the native capture deleted', () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      // The handler, not the case-label list in the subagent device gate.
      final i = src.indexOf('final nativePath = await device.screenshot();');
      expect(i, greaterThan(-1));
      final body = src.substring(i, i + 2200);

      expect(
        body,
        contains('await source.delete()'),
        reason: 'cacheDir/device-captures otherwise fills with PNGs of other '
            "apps' screens",
      );
      // Only after the copy is confirmed on disk.
      expect(
        body.indexOf('copied.exists()'),
        lessThan(body.indexOf('source.delete()')),
      );
      expect(
        body.indexOf('copyScreenshotIntoWorkspace'),
        lessThan(body.indexOf('source.delete()')),
      );
    });
  });

  group('a tool timeout cancels instead of inviting a blind retry', () {
    // Superseded wording: this first shipped as an honest "the command was NOT
    // cancelled" message (which already stopped the retry loop). Per-invocation
    // process tracking now lets the timeout actually KILL the invocation, so the
    // assertion moved to the stronger contract — see tool_timeout_cancel_test.dart
    // for the behavioural coverage (one call's processes die, a run-tagged
    // background job survives).
    test('the message says KILLED and the invocation is killed by key', () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      final i = src.indexOf('final budget = _toolTimeoutFor(name);');
      expect(i, greaterThan(-1));
      // Window covers the zone scoping that precedes the timeout message.
      final region = src.substring(i, i + 3600);

      expect(region, contains('were KILLED'));
      expect(region, contains('killCallProcesses(callKey)'));
      expect(region, contains('do NOT re-run it blindly'));
      expect(
        region,
        isNot(contains('narrow the request (smaller path/pattern/range) and ')),
        reason: 'the original copy told the model to retry, which duplicated '
            'mutating commands',
      );
    });
  });
}
