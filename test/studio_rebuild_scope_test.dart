import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/cloud/studio_remote_client.dart';
import 'package:ovid_ai/core/studio_drafts.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_editor.dart';
import 'package:ovid_ai/ui/studio_file_tree.dart';

import 'support/studio_fake_gateway.dart';

/// F-036: agent notifications that do not touch Studio state no longer
/// re-run the editor's line/column scan or the file-tree flatten.
void main() {
  late FakeStudioGateway fake;
  late StudioRemoteClient remote;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StudioDraftStore.I.disableForTest();
    fake = FakeStudioGateway(
      files: {
        'lib/dir0/f0.dart': List.generate(3000, (i) => 'line $i').join('\n'),
      },
      roots: [
        for (var d = 0; d < 40; d++)
          FakeNode.dir('lib/dir$d', [
            for (var f = 0; f < 50; f++)
              FakeNode.file('lib/dir$d/f$f.dart'),
          ]),
      ],
    );
    remote = installFakeStudio(fake);
  });

  tearDown(() {
    remote.clearAll();
    StudioDraftStore.I.disableForTest();
  });

  Future<void> pumpStudio(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 260,
                height: 600,
                child: StudioFileTree(sessionId: kFakeStudioSession),
              ),
              Expanded(
                child: Column(
                  children: [
                    StudioEditorTabs(sessionId: kFakeStudioSession),
                    Expanded(
                      child: StudioEditor(sessionId: kFakeStudioSession),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('100 agent notifies: tree and line index built at most once', (
    tester,
  ) async {
    await remote.openStudioFile(kFakeStudioSession, 'lib/dir0/f0.dart');
    StudioEditorDebug.lineIndexBuilds = 0;
    debugStudioTreeBuilds = 0;
    await pumpStudio(tester);
    expect(StudioEditorDebug.lineIndexBuilds, greaterThan(0));
    expect(debugStudioTreeBuilds, greaterThan(0));

    debugStudioTreeBuilds = 0;
    StudioEditorDebug.lineIndexBuilds = 0;
    for (var i = 0; i < 100; i++) {
      AgentService.I.refreshNow();
      await tester.pump();
    }
    expect(debugStudioTreeBuilds, lessThanOrEqualTo(1));
    expect(StudioEditorDebug.lineIndexBuilds, lessThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an agent rewrite of the open file still reaches the editor', (
    tester,
  ) async {
    fake.files['a.txt'] = 'before';
    await remote.openStudioFile(kFakeStudioSession, 'a.txt');
    await pumpStudio(tester);

    // A server-side write lands in the bucket and publishes.
    remote.fileBuffer(kFakeStudioSession)['a.txt'] = 'after';
    remote.selectStudioFile(kFakeStudioSession, 'a.txt');
    await tester.pump();

    final field = tester.widget<TextField>(find.byKey(studioEditorFieldKey));
    expect(field.controller!.text, 'after');
  });
}
