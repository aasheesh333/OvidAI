import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/account_health_page.dart';
import 'package:ovid_ai/ui/v2/settings/appearance_page.dart';
import 'package:ovid_ai/ui/v2/settings/credentials_page.dart';
import 'package:ovid_ai/ui/v2/settings/data_control_page.dart';
import 'package:ovid_ai/ui/v2/settings/memory_page.dart';
import 'package:ovid_ai/ui/v2/settings/storage_page.dart';

void _noop() {}

void _toggle(String id, bool value) {}

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
        totalDataSizeLabel: '1.2 GB across 42 chats',
        exportSessions: const [
          V2ExportSession(
            id: 'a',
            name: 'Q3 launch plan',
            detail: '42 messages',
            sizeBytes: 40 * 1024 * 1024,
            sizeLabel: '40 MB',
            heavyArtifacts: true,
          ),
          V2ExportSession(
            id: 'b',
            name: 'Market research',
            detail: '18 messages',
            sizeBytes: 30 * 1024 * 1024,
            sizeLabel: '30 MB',
          ),
        ],
        onDeleteData: _noop,
        onResetMemory: _noop,
        onExportSessionToggled: _toggle,
      ),
    ),
    'storage': StoragePage(
      data: V2StoragePageData(
        usedGb: 1.2,
        totalGb: 3,
        planName: 'Free plan',
        quotaLabel: '3 GB included',
        slices: const [
          V2StorageSlice(
            label: 'Artifacts',
            sizeLabel: '410 MB',
            valueGb: 0.41,
          ),
          V2StorageSlice(label: 'Sessions', sizeLabel: '620 MB', valueGb: 0.62),
          V2StorageSlice(label: 'Cache', sizeLabel: '170 MB', valueGb: 0.17),
        ],
        cacheGb: 0.17,
        cacheSizeLabel: '170 MB',
        largestItems: const [
          V2StorageItem(
            id: 'c1',
            name: 'Q3 launch plan',
            detail: 'Chat · 42 files',
            sizeLabel: '180 MB',
          ),
        ],
        onClearCache: _noop,
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
    'health': const AccountHealthPage(
      data: V2AccountHealthPageData(
        planLabel: 'Plus',
        accountStatus: V2AccountStatus.deletionPending,
        todayUsageLabel: '8.2K tokens',
        storageUsedLabel: '1.2 GB of 15 GB',
        deletionScheduledLabel: '20 Nov 2026',
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
