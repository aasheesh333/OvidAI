import 'package:flutter/material.dart';
import 'package:ovid_ai/ui/v2/sidebar/sidebar.dart';

import 'a11y_support.dart';

void main() {
  group('Sidebar a11y', () {
    Future<void> pumpSidebar(WidgetTester tester, {double textScale = 1.0}) async {
      await pumpA11yScreen(
        tester,
        Sidebar(
          data: V2SidebarData(
            name: 'Ada Lovelace',
            initials: 'AL',
            planLabel: 'Free plan',
            pinned: const [
              V2SidebarSession(
                id: 'p1',
                title: 'Pinned chat',
                modelLabel: 'gpt-4o',
                timeLabel: '2m',
                pinned: true,
              ),
            ],
            projects: const [
              V2SidebarProject(id: 'proj1', name: 'Brand Voice', chatCount: 3),
            ],
            today: const [
              V2SidebarSession(
                id: 's1',
                title: 'Trip planning',
                modelLabel: 'claude-3-5',
                timeLabel: '1h',
              ),
            ],
          ),
          onNewChat: () {},
          onNewProject: () {},
          onProjectTap: (_) {},
          onSessionTap: (_) {},
          onSessionActions: (_) {},
          onSettings: () {},
          onArtifacts: () {},
          onSchedule: () {},
        ),
        textScale: textScale,
        size: const Size(340, 844),
      );
    }

    testWidgets('meets a11y guidelines at 1.0, 1.5 and 2.0 text scale',
        (tester) async {
      await expectA11yAtScales(tester, 'Sidebar', (scale) async {
        await pumpSidebar(tester, textScale: scale);
      });
    });

    testWidgets('no overflow at 2.0 text scale', (tester) async {
      await pumpSidebar(tester, textScale: 2.0);
      expect(tester.takeException(), isNull);
    });
  });
}
