import 'package:flutter/material.dart';
import 'package:ovid_ai/ui/v2/studio/studio_workspace_page.dart';

import 'a11y_support.dart';

void main() {
  group('V2StudioWorkspacePage a11y', () {
    Future<void> pumpWorkspace(WidgetTester tester, {double textScale = 1.0}) async {
      await pumpA11yScreen(
        tester,
        V2StudioWorkspacePage(
          data: V2StudioWorkspaceData(
            repoName: 'ovid-backend',
            branch: 'main',
            status: V2WorkspaceStatus.content,
            fileTree: const [
              V2FileNode(
                name: 'lib',
                path: 'lib',
                children: [
                  V2FileNode(name: 'main.dart', path: 'lib/main.dart'),
                ],
              ),
              V2FileNode(name: 'README.md', path: 'README.md'),
            ],
            openFileName: 'main.dart',
            openFilePath: 'lib/main.dart',
            codeLines: const [
              V2CodeLine(number: 1, text: 'void main() {}'),
            ],
          ),
          onSelectFile: (_) {},
          onBranchTap: () {},
          onSync: () {},
          onViewRuns: () {},
        ),
        textScale: textScale,
        size: const Size(1200, 900),
      );
    }

    testWidgets('meets a11y guidelines at 1.0, 1.5 and 2.0 text scale',
        (tester) async {
      await expectA11yAtScales(tester, 'V2StudioWorkspacePage', (scale) async {
        await pumpWorkspace(tester, textScale: scale);
      });
    });

    testWidgets('no overflow at 2.0 text scale', (tester) async {
      await pumpWorkspace(tester, textScale: 2.0);
      expect(tester.takeException(), isNull);
    });
  });
}
