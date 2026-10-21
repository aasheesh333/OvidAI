import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/account_health_page.dart';
import 'package:ovid_ai/ui/v2/settings/appearance_page.dart';
import 'package:ovid_ai/ui/v2/settings/credentials_page.dart';
import 'package:ovid_ai/ui/v2/settings/data_control_page.dart';
import 'package:ovid_ai/ui/v2/settings/memory_page.dart';
import 'package:ovid_ai/ui/v2/settings/storage_page.dart';

void main() {
  final screens = <String, Widget>{
    'memory': MemoryPage(
      data: V2MemoryPageData(
        globalMemory: const ['Prefers plain English.', 'Works as a designer.'],
        projects: const [
          V2MemoryProject(
            id: 'p1',
            name: 'Mobile App Redesign',
            detail: '4 rules',
          ),
        ],
        sessionFiles: const [
          V2MemoryFile(id: 'f1', name: 'architecture-spec.md', detail: '42 KB'),
        ],
      ),
    ),
    'data': DataControlPage(
      data: V2DataControlPageData(
        importValidation: const V2ImportValidation(
          fileName: 'ovid-backup-2026-10-21.zip',
          message: 'Ready to import: 12 MB · 42 chats · 860 messages.',
          valid: true,
        ),
      ),
    ),
    'storage': StoragePage(
      data: V2StoragePageData(
        largestItems: const [
          V2StorageItem(
            id: 'c1',
            name: 'Q3 launch plan',
            detail: 'Chat · 42 files',
            sizeLabel: '180 MB',
          ),
        ],
      ),
    ),
    'appearance': AppearancePage(
      data: V2AppearancePageData(
        preview: const V2AppearancePreview(
          sessionLabel: 'Session #408',
          statusLabel: 'Ready',
          userMessage: 'Can you analyze this repo structure?',
          assistantMessage: 'I indexed 14 components.',
        ),
      ),
    ),
    'credentials': CredentialsPage(
      data: V2CredentialsPageData(
        google: const V2Credential(
          id: 'g',
          kind: V2CredentialKind.google,
          title: 'Google',
          subtitle: 'aarav@gmail.com',
        ),
        github: const V2Credential(
          id: 'gh',
          kind: V2CredentialKind.github,
          title: 'GitHub',
          subtitle: 'aarav-sharma',
        ),
        token: const V2Credential(
          id: 't',
          kind: V2CredentialKind.token,
          title: 'Personal access token',
          subtitle: 'pat_live_••••••9x4q',
        ),
      ),
    ),
    'health': AccountHealthPage(
      data: V2AccountHealthPageData(
        twoFactorEnabled: false,
        devices: const [
          V2SignInDevice(
            id: 'p',
            name: 'Pixel 9 Pro',
            detail: 'Signed in now',
            current: true,
          ),
          V2SignInDevice(
            id: 'm',
            name: 'MacBook Air',
            detail: 'Last active yesterday',
          ),
        ],
        recentSignIns: const [
          V2SignInEvent(
            id: 's',
            device: 'Pixel 9 Pro',
            location: 'Mumbai, India',
            timeLabel: 'Today at 9:12 AM',
          ),
        ],
      ),
    ),
  };

  for (final entry in screens.entries) {
    for (final dark in [false, true]) {
      testWidgets(
        '${entry.key} at 320 dp and 200% text (${dark ? 'dark' : 'light'})',
        (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? OTheme.dark() : OTheme.light(),
              home: MediaQuery(
                data: const MediaQueryData(
                  size: Size(320, 640),
                  textScaler: TextScaler.linear(2),
                ),
                child: entry.value,
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
