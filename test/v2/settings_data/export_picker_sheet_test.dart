import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/export_picker_sheet.dart';

const _mb = 1024 * 1024;

const _sessions = <V2ExportPickerSession>[
  V2ExportPickerSession(
    id: 'launch',
    name: 'Q3 launch plan',
    detail: '420 messages',
    messageCount: 420,
    sizeBytes: 40 * _mb,
    heavyArtifacts: true,
  ),
  V2ExportPickerSession(
    id: 'research',
    name: 'Market research',
    detail: '300 messages',
    messageCount: 300,
    sizeBytes: 30 * _mb,
  ),
  V2ExportPickerSession(
    id: 'notes',
    name: 'Meeting notes',
    detail: '200 messages',
    messageCount: 200,
    sizeBytes: 20 * _mb,
  ),
];

Widget _app(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? OTheme.light(),
  home: Scaffold(body: child),
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
}) async {
  await tester.pumpWidget(_app(child, theme: theme));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// Pumps the sheet on a 320 dp wide phone at 200 % text. A RenderFlex overflow
/// surfaces as a framework exception, which fails the test.
Future<void> _pumpNarrow(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
  double textScale = 2,
}) async {
  tester.view.physicalSize = const Size(320, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? OTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(320, 700),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

V2ExportPickerSheetData _data({
  List<V2ExportPickerSession> sessions = _sessions,
  V2ExportPickerStatus status = V2ExportPickerStatus.ready,
}) => V2ExportPickerSheetData(sessions: sessions, status: status);

V2ExportPickerSession _select(
  V2ExportPickerSession session, {
  required bool selected,
}) => V2ExportPickerSession(
  id: session.id,
  name: session.name,
  sizeBytes: session.sizeBytes,
  sizeLabel: session.sizeLabel,
  messageCount: session.messageCount,
  detail: session.detail,
  selected: selected,
  heavyArtifacts: session.heavyArtifacts,
);

/// Applies a toggle to an immutable session list, the way the live adapter
/// would, so a test can drive the sheet like the real screen.
List<V2ExportPickerSession> _toggleSelection(
  List<V2ExportPickerSession> sessions,
  String id,
  bool selected,
) => [
  for (final session in sessions)
    session.id == id ? _select(session, selected: selected) : session,
];

void main() {
  testWidgets('picker shows the title, running totals and every chat', (
    tester,
  ) async {
    await _pump(tester, ExportPickerSheet(data: _data()));

    expect(find.text('Export chats'), findsOneWidget);
    expect(find.text('90 MB of 64 MB selected'), findsOneWidget);
    expect(find.text('3 of 1,000 chats'), findsOneWidget);
    expect(find.text('920 of 20,000 messages'), findsOneWidget);
    expect(find.text('Select all'), findsOneWidget);
    expect(find.text('3 of 3 chats selected'), findsOneWidget);

    expect(find.text('Q3 launch plan'), findsOneWidget);
    expect(find.text('Market research'), findsOneWidget);
    expect(find.text('Meeting notes'), findsOneWidget);
    // Select-all plus one checkbox per chat.
    expect(find.byType(Checkbox), findsNWidgets(4));
  });

  testWidgets('picker renders in dark theme', (tester) async {
    await _pump(tester, ExportPickerSheet(data: _data()), theme: OTheme.dark());

    expect(find.text('Export chats'), findsOneWidget);
    expect(find.text('90 MB of 64 MB selected'), findsOneWidget);
  });

  testWidgets('over-limit selection disables export and says how to fix it', (
    tester,
  ) async {
    var exported = false;
    await _pump(
      tester,
      ExportPickerSheet(
        data: _data(),
        onExport: () => exported = true,
        onToggleSession: (_, _) {},
      ),
    );

    expect(
      find.text('Deselect chats until the total is 64 MB or less.'),
      findsWidgets,
    );
    final button = tester.widget<OButton>(
      find.byKey(const ValueKey('export-picker-export')),
    );
    expect(button.onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('export-picker-export')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(exported, isFalse);
  });

  testWidgets('a selection under every limit can be exported', (tester) async {
    var exported = false;
    await _pump(
      tester,
      ExportPickerSheet(
        data: _data(
          sessions: [
            _select(_sessions[0], selected: true),
            _select(_sessions[1], selected: false),
            _select(_sessions[2], selected: false),
          ],
        ),
        onExport: () => exported = true,
        onToggleSession: (_, _) {},
      ),
    );

    expect(find.text('40 MB of 64 MB selected'), findsOneWidget);
    final button = tester.widget<OButton>(
      find.byKey(const ValueKey('export-picker-export')),
    );
    expect(button.onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('export-picker-export')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(exported, isTrue);
  });

  testWidgets('checkbox reports the chat id and its new value', (tester) async {
    String? toggledId;
    bool? toggledValue;
    await _pump(
      tester,
      ExportPickerSheet(
        data: _data(),
        onToggleSession: (id, value) {
          toggledId = id;
          toggledValue = value;
        },
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('export-picker-session-launch')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(toggledId, 'launch');
    expect(toggledValue, isFalse);
  });

  testWidgets('toggling a chat moves the running total', (tester) async {
    await _pump(
      tester,
      _PickerHarness(
        initialSelected: const {'notes'},
        sessions: [
          _select(_sessions[0], selected: false),
          _select(_sessions[1], selected: false),
          _select(_sessions[2], selected: true),
        ],
      ),
    );

    expect(find.text('20 MB of 64 MB selected'), findsOneWidget);
    expect(find.text('1 of 1,000 chats'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('export-picker-session-launch')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('60 MB of 64 MB selected'), findsOneWidget);
    expect(find.text('2 of 1,000 chats'), findsOneWidget);
  });

  testWidgets('a chat that would break the 64 MB cap is disabled', (
    tester,
  ) async {
    var toggles = 0;
    await _pump(
      tester,
      ExportPickerSheet(
        data: _data(
          sessions: [
            _select(_sessions[0], selected: false),
            _select(_sessions[1], selected: true),
            _select(_sessions[2], selected: false),
          ],
        ),
        onToggleSession: (_, _) => toggles++,
      ),
    );

    // 30 MB is selected. Adding the 40 MB chat would reach 70 MB.
    final launch = tester.widget<Checkbox>(
      find.byKey(const ValueKey('export-picker-session-launch')),
    );
    expect(launch.onChanged, isNull);
    expect(find.text('Over the 64 MB limit'), findsOneWidget);

    // A 30 MB chat still fits (60 MB total).
    final research = tester.widget<Checkbox>(
      find.byKey(const ValueKey('export-picker-session-research')),
    );
    expect(research.onChanged, isNotNull);

    await tester.tap(
      find.byKey(const ValueKey('export-picker-session-launch')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(toggles, 0);
  });

  testWidgets('a chat that would break the message cap is disabled', (
    tester,
  ) async {
    await _pump(
      tester,
      ExportPickerSheet(
        data: _data(
          sessions: [
            const V2ExportPickerSession(
              id: 'long',
              name: 'Year of standups',
              sizeBytes: 1 * _mb,
              messageCount: 19900,
              selected: true,
            ),
            const V2ExportPickerSession(
              id: 'extra',
              name: 'New standup',
              sizeBytes: 1 * _mb,
              messageCount: 200,
              selected: false,
            ),
          ],
        ),
        onToggleSession: (_, _) {},
      ),
    );

    final extra = tester.widget<Checkbox>(
      find.byKey(const ValueKey('export-picker-session-extra')),
    );
    expect(extra.onChanged, isNull);
    expect(find.text('Over the 20,000 message limit'), findsOneWidget);
    expect(find.text('19,900 of 20,000 messages'), findsOneWidget);
  });

  testWidgets('a chat that would break the chat cap is disabled', (
    tester,
  ) async {
    final sessions = [
      const V2ExportPickerSession(
        id: 'one',
        name: 'First chat',
        sizeBytes: 1 * _mb,
        messageCount: 2,
        selected: true,
      ),
      const V2ExportPickerSession(
        id: 'two',
        name: 'Second chat',
        sizeBytes: 1 * _mb,
        messageCount: 2,
        selected: true,
      ),
      const V2ExportPickerSession(
        id: 'three',
        name: 'Third chat',
        sizeBytes: 1 * _mb,
        messageCount: 2,
        selected: false,
      ),
    ];
    await _pump(
      tester,
      ExportPickerSheet(
        data: V2ExportPickerSheetData(
          sessions: sessions,
          limitChats: 2,
          limitMessages: 100,
        ),
        onToggleSession: (_, _) {},
      ),
    );

    final third = tester.widget<Checkbox>(
      find.byKey(const ValueKey('export-picker-session-three')),
    );
    expect(third.onChanged, isNull);
    expect(find.text('Over the 2 chat limit'), findsOneWidget);
  });

  testWidgets('select all adds only the chats that fit', (tester) async {
    List<String>? ids;
    await _pump(
      tester,
      ExportPickerSheet(
        data: _data(
          sessions: [
            _select(_sessions[0], selected: true),
            _select(_sessions[1], selected: false),
            _select(_sessions[2], selected: false),
          ],
        ),
        onToggleSession: (_, _) {},
        onSelectAll: (value) => ids = value,
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('export-picker-select-all-checkbox')),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // Launch (40 MB) is already selected. Notes (20 MB) fits in 64 MB;
    // adding research too would reach 90 MB, so it is left out.
    expect(ids, ['launch', 'notes']);
  });

  testWidgets('select all clears a full selection', (tester) async {
    List<String>? ids;
    await _pump(
      tester,
      ExportPickerSheet(
        data: _data(),
        onToggleSession: (_, _) {},
        onSelectAll: (value) => ids = value,
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('export-picker-select-all-checkbox')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(ids, isEmpty);
  });

  testWidgets('select all is disabled when nothing else fits', (tester) async {
    await _pump(
      tester,
      ExportPickerSheet(
        data: V2ExportPickerSheetData(
          sessions: [
            const V2ExportPickerSession(
              id: 'only',
              name: 'Too large',
              sizeBytes: 90 * _mb,
              selected: false,
            ),
          ],
          limitChats: 1,
        ),
        onToggleSession: (_, _) {},
        onSelectAll: (_) {},
      ),
    );

    final selectAll = tester.widget<Checkbox>(
      find.byKey(const ValueKey('export-picker-select-all-checkbox')),
    );
    expect(selectAll.onChanged, isNull);
  });

  testWidgets('disabled rows announce the blocking limit', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      ExportPickerSheet(
        data: _data(
          sessions: [
            _select(_sessions[0], selected: false),
            _select(_sessions[1], selected: true),
            _select(_sessions[2], selected: false),
          ],
        ),
        onToggleSession: (_, _) {},
      ),
    );

    expect(
      tester.getSemantics(
        find.byKey(const ValueKey('export-picker-session-launch')),
      ),
      matchesSemantics(
        label:
            'Include Q3 launch plan, 40 MB. Not available: it would go over '
            'the 64 MB limit.',
        hasCheckedState: true,
        isChecked: false,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    handle.dispose();
  });

  testWidgets('enabled rows announce the chat and its selected state', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      ExportPickerSheet(data: _data(), onToggleSession: (_, _) {}),
    );

    expect(
      tester.getSemantics(
        find.byKey(const ValueKey('export-picker-session-research')),
      ),
      matchesSemantics(
        label: 'Exclude Market research, 30 MB',
        hint: 'Deselects this chat',
        hasCheckedState: true,
        isChecked: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('heavy artifacts note warns what must be re-uploaded', (
    tester,
  ) async {
    await _pump(tester, ExportPickerSheet(data: _data()));

    await tester.scrollUntilVisible(
      find.text('Q3 launch plan'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    expect(find.textContaining('must be re-uploaded'), findsWidgets);
  });

  testWidgets('loading state shows skeletons', (tester) async {
    await _pump(
      tester,
      ExportPickerSheet(data: _data(status: V2ExportPickerStatus.loading)),
    );

    expect(find.text('Export chats'), findsOneWidget);
    expect(find.byType(OSkeletonList), findsOneWidget);
  });

  testWidgets('empty state explains the next step and fires its action', (
    tester,
  ) async {
    var closed = 0;
    await _pump(
      tester,
      ExportPickerSheet(
        data: _data(sessions: const []),
        onClose: () => closed++,
      ),
    );

    expect(find.text('No chats to export'), findsOneWidget);
    expect(
      find.text('Start a chat, then come back.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Back to data control'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(closed, 1);
  });

  testWidgets('error state offers a retry', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      ExportPickerSheet(
        data: _data(status: V2ExportPickerStatus.error),
        onRetry: () => retries++,
      ),
    );

    expect(find.text('Could not load chats'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(retries, 1);
  });

  testWidgets('opens in the shared bottom sheet at 320 dp and 200 % text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 700),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: OButton(
                  label: 'Open picker',
                  onPressed: () => showExportPickerSheet(
                    context,
                    data: _data(),
                    onToggleSession: (_, _) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();

    expect(find.text('Export chats'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('over-limit picker fits 320 dp at 200 % text', (tester) async {
    await _pumpNarrow(tester, ExportPickerSheet(data: _data()));

    expect(tester.takeException(), isNull);
    expect(find.text('Export chats'), findsOneWidget);
    expect(
      find.text('Deselect chats until the total is 64 MB or less.'),
      findsOneWidget,
    );

    // Reach the summary and the heavy chat at the bottom of the list.
    await tester.scrollUntilVisible(
      find.text('90 MB of 64 MB selected'),
      80,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(find.text('90 MB of 64 MB selected'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('over-limit picker fits 320 dp at 200 % text in dark theme', (
    tester,
  ) async {
    await _pumpNarrow(
      tester,
      ExportPickerSheet(data: _data()),
      theme: OTheme.dark(),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('empty and error states fit 320 dp at 200 % text', (
    tester,
  ) async {
    for (final status in [
      V2ExportPickerStatus.ready,
      V2ExportPickerStatus.loading,
      V2ExportPickerStatus.error,
    ]) {
      await _pumpNarrow(
        tester,
        ExportPickerSheet(
          data: _data(sessions: const [], status: status),
          onClose: () {},
          onRetry: () {},
        ),
      );
      expect(tester.takeException(), isNull, reason: 'status $status');
    }
  });
}

/// Small stateful adapter used to prove the sheet rebuilds with new totals.
class _PickerHarness extends StatefulWidget {
  const _PickerHarness({required this.sessions, required this.initialSelected});

  final List<V2ExportPickerSession> sessions;
  final Set<String> initialSelected;

  @override
  State<_PickerHarness> createState() => _PickerHarnessState();
}

class _PickerHarnessState extends State<_PickerHarness> {
  late List<V2ExportPickerSession> _sessions = [
    for (final session in widget.sessions)
      _select(session, selected: widget.initialSelected.contains(session.id)),
  ];

  @override
  Widget build(BuildContext context) {
    return ExportPickerSheet(
      data: V2ExportPickerSheetData(sessions: _sessions),
      onToggleSession: (id, selected) {
        setState(() {
          _sessions = _toggleSelection(_sessions, id, selected);
        });
      },
      onSelectAll: (ids) {
        setState(() {
          _sessions = [
            for (final session in _sessions)
              _select(session, selected: ids.contains(session.id)),
          ];
        });
      },
    );
  }
}
