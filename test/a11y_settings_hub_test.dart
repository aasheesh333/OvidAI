import 'package:flutter/material.dart';
import 'package:ovid_ai/ui/v2/settings/settings_hub.dart';

import 'a11y_support.dart';

void main() {
  group('SettingsHubPage a11y', () {
    Future<void> pumpSettings(WidgetTester tester, {double textScale = 1.0}) async {
      await pumpA11yScreen(
        tester,
        SettingsHubPage(
          data: V2SettingsHubData(
            profile: const V2SettingsProfile(
              name: 'Ada Lovelace',
              email: 'ada@example.com',
              planLabel: 'Free plan',
              initials: 'AL',
            ),
            account: V2SettingsSection(
              title: 'Account',
              items: [
                V2SettingsItem(
                  id: 'account',
                  label: 'Account',
                  icon: Icons.account_circle_outlined,
                  onTap: () {},
                ),
              ],
            ),
            chat: V2SettingsSection(
              title: 'Personalization',
              items: [
                V2SettingsItem(
                  id: 'appearance',
                  label: 'Appearance',
                  icon: Icons.palette_outlined,
                  onTap: () {},
                ),
              ],
            ),
            models: V2SettingsSection(
              title: 'Models',
              items: [
                V2SettingsItem(
                  id: 'connectors',
                  label: 'Connectors',
                  icon: Icons.hub_outlined,
                  onTap: () {},
                ),
              ],
            ),
            dataControl: V2SettingsSection(
              title: 'Data control',
              items: [
                V2SettingsItem(
                  id: 'export_import',
                  label: 'Export / import',
                  icon: Icons.import_export_outlined,
                  onTap: () {},
                ),
              ],
            ),
            advanced: V2SettingsSection(
              title: 'Advanced',
              items: [
                V2SettingsItem(
                  id: 'about',
                  label: 'About',
                  icon: Icons.info_outline_rounded,
                  onTap: () {},
                ),
              ],
            ),
            onSignOut: () {},
          ),
        ),
        textScale: textScale,
      );
    }

    testWidgets('meets a11y guidelines at 1.0, 1.5 and 2.0 text scale',
        (tester) async {
      await expectA11yAtScales(tester, 'SettingsHubPage', (scale) async {
        await pumpSettings(tester, textScale: scale);
      });
    });

    testWidgets('no overflow at 2.0 text scale', (tester) async {
      await pumpSettings(tester, textScale: 2.0);
      expect(tester.takeException(), isNull);
    });
  });
}
