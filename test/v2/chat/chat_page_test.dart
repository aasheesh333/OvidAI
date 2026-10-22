import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_motion.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/composer_attachments.dart';
import 'package:ovid_ai/ui/v2/chat/composer_row.dart';
import 'package:ovid_ai/ui/v2/chat/model_chip.dart';
import 'package:ovid_ai/ui/v2/chat/queue_dock.dart';

Widget _app(Widget home, {bool dark = false}) =>
    MaterialApp(theme: dark ? OTheme.dark() : OTheme.light(), home: home);

void main() {
  testWidgets('renders the top bar, empty state and suggestions in light', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          onModelChipTap: () {},
          onMenu: () {},
          onStudio: () {},
          onBrowser: () {},
          onMore: () {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    // The wordmark is the empty state, so the name reads twice: once in the
    // top bar, once as the brand in the body.
    // The empty state no longer repeats the wordmark the top bar already
    // carries; one occurrence is correct.
    expect(find.text('Ovid Si'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('What should we build?'), findsOneWidget);
    // The empty state is the wordmark, one short line and three chips; the
    // explainer paragraph is gone.
    expect(find.text('Ask anything. Ovid works in the background.'), findsNothing);
    expect(find.text('Build a landing page'), findsOneWidget);
    expect(find.text('Research a topic'), findsOneWidget);
    expect(find.text('Fix a repo bug'), findsOneWidget);
    // The model and token line above the composer was permanent chrome; the
    // model chip in the header is the one place model state lives.
    expect(find.text('Auto · 50M tokens left today'), findsNothing);
    expect(find.text('Fast agent'), findsNothing);
    // The permission chip is a control: with no handler it is not shown at all.
    expect(find.text('General'), findsNothing);
  });

  testWidgets('renders in dark', (tester) async {
    await tester.pumpWidget(
      _app(const V2ChatPage(data: V2ChatPageData()), dark: true),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('What should we build?'), findsOneWidget);
  });

  testWidgets('suggestion card fires and fills the composer', (tester) async {
    V2ChatSuggestion? tapped;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          onSuggestionTap: (suggestion) => tapped = suggestion,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Build a landing page'));
    await tester.pump();

    expect(tapped, isNotNull);
    expect(tapped!.title, 'Build a landing page');
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Build a landing page');
  });

  testWidgets('draft is controlled by data and emits changes', (tester) async {
    String? changed;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(draft: 'Start here'),
          onDraftChanged: (value) => changed = value,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Start here');

    await tester.enterText(find.byType(TextField), 'Keep going');
    expect(changed, 'Keep going');
  });

  testWidgets('send callback carries the typed text', (tester) async {
    String? sent;
    await tester.pumpWidget(
      _app(
        V2ChatPage(data: const V2ChatPageData(), onSend: (text) => sent = text),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(find.byType(TextField), 'Build a pricing page');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();

    expect(sent, 'Build a pricing page');
  });

  testWidgets('model chip and top bar actions report taps', (tester) async {
    var modelTaps = 0;
    var studioTaps = 0;
    var browserTaps = 0;
    var moreTaps = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          onModelChipTap: () => modelTaps++,
          onStudio: () => studioTaps++,
          onBrowser: () => browserTaps++,
          onMore: () => moreTaps++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Auto'));
    await tester.tap(find.bySemanticsLabel('Open Studio'));
    await tester.tap(find.bySemanticsLabel('Open Browser'));
    await tester.tap(find.bySemanticsLabel('More options'));
    await tester.pump();

    expect(modelTaps, 1);
    expect(studioTaps, 1);
    expect(browserTaps, 1);
    expect(moreTaps, 1);
  });

  testWidgets('tablet centres the home column and the composer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(const V2ChatPage(data: V2ChatPageData())));
    await tester.pump(const Duration(milliseconds: 400));

    final scroll = find
        .ancestor(
          of: find.text('What should we build?'),
          matching: find.byType(SingleChildScrollView),
        )
        .first;
    expect(tester.getSize(scroll).width, lessThanOrEqualTo(720));
    expect(tester.getCenter(scroll).dx, closeTo(500, 1));

    final composer = find.byKey(const ValueKey('v2-chat-composer-column'));
    expect(tester.getSize(composer).width, lessThanOrEqualTo(720));
    expect(tester.getTopLeft(composer).dx, closeTo((1000 - 720) / 2, 1));

    // 600–899 dp keeps the contract's 640 column, still centred and never
    // wider than the 720 cap.
    tester.view.physicalSize = const Size(800, 800);
    await tester.pumpWidget(_app(const V2ChatPage(data: V2ChatPageData())));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getSize(composer).width, lessThanOrEqualTo(640));
    expect(tester.getCenter(composer).dx, closeTo(400, 1));
  });

  testWidgets('loading state shows history skeletons', (tester) async {
    await tester.pumpWidget(
      _app(const V2ChatPage(data: V2ChatPageData(state: V2ChatState.loading))),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(OSkeletonList), findsOneWidget);
  });

  testWidgets('error state retries', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(state: V2ChatState.error),
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('That did not work'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('offline queue explains that messages will send later', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(
            state: V2ChatState.offline,
            queuedCount: 2,
          ),
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text("You're offline"), findsOneWidget);
    expect(find.text('Your message is saved and sends when you reconnect.'), findsOneWidget);
    expect(find.text('2 messages are waiting to send.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retries, 1);
  });

  testWidgets('daily limit state shows reset time and plans action', (
    tester,
  ) async {
    var plans = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(state: V2ChatState.planLimited),
          onSeePlans: () => plans++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Daily limit reached'), findsOneWidget);
    expect(
      find.text("You've reached your plan's daily limit."),
      findsOneWidget,
    );
    await tester.tap(find.text('See plans'));
    expect(plans, 1);
  });

  testWidgets('running state is one status line and one stop control', (
    tester,
  ) async {
    var stops = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(state: V2ChatState.running),
          onStop: () => stops++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Ovid is working'), findsOneWidget);
    // Stop lives in the composer's send slot, so the same action never gets a
    // second button in the body.
    expect(find.widgetWithText(OButton, 'Stop'), findsNothing);
    final stop = find.bySemanticsLabel('Stop');
    expect(stop, findsOneWidget);
    await tester.tap(stop);
    await tester.pump();
    expect(stops, 1);
  });

  for (final dark in [false, true]) {
    testWidgets(
      '320 dp at 200% text lays out cleanly (${dark ? 'dark' : 'light'})',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final errors = <FlutterErrorDetails>[];
        final previous = FlutterError.onError;
        FlutterError.onError = errors.add;
        addTearDown(() => FlutterError.onError = previous);

        for (final state in V2ChatState.values) {
          errors.clear();
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? OTheme.dark() : OTheme.light(),
              home: MediaQuery(
                data: const MediaQueryData(
                  size: Size(320, 640),
                  textScaler: TextScaler.linear(2),
                ),
                child: V2ChatPage(
                  data: V2ChatPageData(state: state, queuedCount: 2),
                  onSend: (_) {},
                  onStop: () {},
                  onRetry: () {},
                  onSeePlans: () {},
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));

          for (final error in errors) {
            debugPrint('$state: $error');
          }
          expect(errors, isEmpty, reason: 'state $state overflowed');
        }
      },
    );
  }

  testWidgets('composer controls are reachable and labelled at 320 dp', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var attaches = 0;
    var mics = 0;
    var permissions = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          onMenu: () {},
          onMore: () {},
          onAttach: () => attaches++,
          onMic: () => mics++,
          onPermissionTap: () => permissions++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    for (final label in [
      'Open menu',
      'More options',
      'Add attachment or action',
      'Voice input',
    ]) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
      final size = tester.getSize(find.bySemanticsLabel(label));
      expect(size.width, greaterThanOrEqualTo(48), reason: label);
      expect(size.height, greaterThanOrEqualTo(48), reason: label);
    }
    // Below 360 dp the header keeps one action (the contract's budget).
    expect(find.bySemanticsLabel('Open Studio'), findsNothing);
    expect(find.bySemanticsLabel('Open Browser'), findsNothing);

    final permission = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.label == 'Permission: General. Change' &&
          widget.properties.button == true,
    );
    expect(permission, findsOneWidget);
    expect(tester.getSize(permission).height, greaterThanOrEqualTo(48));

    // Exactly one control row, in the contract order:
    // +, permission, field, mic, send.
    final stack = tester.widget<Column>(
      find.byKey(const ValueKey('v2-chat-composer-stack')),
    );
    expect(stack.children.whereType<V2ComposerRow>(), hasLength(1));
    expect(stack.children.whereType<Row>(), isEmpty);

    final plus = find.bySemanticsLabel('Add attachment or action');
    final field = find.byType(TextField);
    final mic = find.bySemanticsLabel('Voice input');
    final send = find.bySemanticsLabel('Send');
    final centres = [plus, permission, field, mic, send]
        .map(tester.getCenter)
        .toList();
    for (var i = 1; i < centres.length; i++) {
      expect(
        centres[i].dx,
        greaterThan(centres[i - 1].dx),
        reason: 'control $i must sit right of control ${i - 1}',
      );
      expect(
        centres[i].dy,
        closeTo(centres.first.dy, 1),
        reason: 'control $i must share the composer row',
      );
    }
    expect(tester.widget<TextField>(field).minLines, 1);
    expect(tester.widget<TextField>(field).maxLines, 3);

    // The "+" opens the composer's own menu; its File row reaches the host's
    // legacy attach seam.
    await tester.tap(find.bySemanticsLabel('Add attachment or action'));
    await tester.pumpAndSettle();
    final fileRow = find.byKey(const ValueKey('composer-plus-file'));
    await tester.ensureVisible(fileRow);
    await tester.pumpAndSettle();
    await tester.tap(fileRow);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Voice input'));
    await tester.tap(permission);
    await tester.pump();

    expect(attaches, 1);
    expect(mics, 1);
    expect(permissions, 1);
  });

  testWidgets('at 320 dp and 200 % text the permission chip moves to the + sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var permissions = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: V2ChatPage(
            data: const V2ChatPageData(),
            onPermissionTap: () => permissions++,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    // The row stays one line: the chip leaves it instead of wrapping.
    expect(find.bySemanticsLabel('Permission: General. Change'), findsNothing);
    expect(
      tester
          .widget<Column>(find.byKey(const ValueKey('v2-chat-composer-stack')))
          .children
          .whereType<Row>(),
      isEmpty,
    );

    await tester.tap(find.bySemanticsLabel('Add attachment or action'));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('composer-plus-permission'));
    expect(row, findsOneWidget);
    expect(find.text('Permission: General'), findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(permissions, 1);
  });

  testWidgets('send is announced as disabled until a draft exists', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    // A composer with a real send handler: with none, Send stays disabled by
    // design (no control may announce a send that goes nowhere).
    await tester.pumpWidget(
      _app(V2ChatPage(data: const V2ChatPageData(), onSend: (_) {})),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      tester.getSemantics(find.bySemanticsLabel('Send')),
      isSemantics(
        label: 'Send',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );

    await tester.enterText(find.byType(TextField), 'Hello');
    await tester.pump();

    expect(
      tester.getSemantics(find.bySemanticsLabel('Send')),
      isSemantics(
        label: 'Send',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('a long model label does not break the top bar', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previous);

    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(modelLabel: 'Ovid Si Pro Reasoning'),
          onModelChipTap: () {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(errors, isEmpty);
    // Top bar and the empty-state wordmark both carry the name.
    // The empty state no longer repeats the wordmark the top bar already
    // carries; one occurrence is correct.
    expect(find.text('Ovid Si'), findsOneWidget);
  });

  testWidgets('top bar uses the shared model chip with plan and subagents', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(
            modelLabel: 'Ovid Pro 1.5',
            autoOnly: true,
            subagentCount: 3,
          ),
          onModelChipTap: () => taps++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    final chip = tester.widget<V2ModelChip>(find.byType(V2ModelChip));
    expect(chip.label, 'Ovid Pro 1.5');
    expect(chip.autoOnly, isTrue);
    expect(chip.subagentCount, 3);
    expect(chip.enabled, isTrue);
    expect(
      find.bySemanticsLabel(
        'Model: Ovid Pro 1.5. Auto only. 3 subagents. Change model',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byType(V2ModelChip));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('a model chip without a handler is not drawn', (tester) async {
    await tester.pumpWidget(_app(const V2ChatPage(data: V2ChatPageData())));
    await tester.pump(const Duration(milliseconds: 400));

    // Model selection exists in the app, but this host supplied no way to
    // open it. A grey chip that announces "unavailable" is still a control
    // that cannot act, so the bar shows the title alone.
    expect(find.byType(V2ModelChip), findsNothing);
    expect(find.text('Auto'), findsNothing);
    expect(find.text('Ovid Si'), findsOneWidget);
  });

  testWidgets('header actions without handlers are not drawn', (tester) async {
    await tester.pumpWidget(_app(const V2ChatPage(data: V2ChatPageData())));
    await tester.pump(const Duration(milliseconds: 400));

    for (final label in [
      'Open menu',
      'Open Studio',
      'Open Browser',
      'More options',
    ]) {
      expect(find.bySemanticsLabel(label), findsNothing, reason: label);
    }
  });

  testWidgets('plus callback replaces the file picker', (tester) async {
    var plus = 0;
    var attaches = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          onPlus: () => plus++,
          onAttach: () => attaches++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.bySemanticsLabel('Add attachment or action'), findsOneWidget);
    expect(find.bySemanticsLabel('Attach a file'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Add attachment or action'));
    await tester.pump();

    expect(plus, 1);
    expect(attaches, 0);
  });

  testWidgets('composer opens its plus menu and File reaches the host seam', (
    tester,
  ) async {
    var attaches = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(data: const V2ChatPageData(), onAttach: () => attaches++),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.bySemanticsLabel('Add attachment or action'), findsOneWidget);
    expect(find.bySemanticsLabel('Attach a file'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Add attachment or action'));
    await tester.pumpAndSettle();
    expect(find.text('Add to chat'), findsOneWidget);

    final fileRow = find.byKey(const ValueKey('composer-plus-file'));
    await tester.ensureVisible(fileRow);
    await tester.pumpAndSettle();
    await tester.tap(fileRow);
    await tester.pumpAndSettle();

    expect(attaches, 1);
    expect(find.text('Add to chat'), findsNothing);
  });

  testWidgets('queued messages surface in the dock above the composer', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(queuedCount: 2),
          onStop: _noop,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(V2QueueDock), findsOneWidget);
    expect(find.text('2 queued'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(V2QueueDock)).dy,
      lessThan(tester.getTopLeft(find.byType(TextField)).dy),
    );
  });

  testWidgets('plus menu File and Photo stage through their own pickers', (
    tester,
  ) async {
    final files = <String>[];
    final images = <String>[];
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          attachmentPicker: () async {
            files.add('file');
            return const [
              V2ComposerAttachment(
                name: 'brief.md',
                path: '/tmp/brief.md',
                size: 2048,
              ),
            ];
          },
          imagePicker: () async {
            images.add('image');
            return const [
              V2ComposerAttachment(
                name: 'shot.png',
                path: '/tmp/shot.png',
                size: 4096,
              ),
            ];
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.bySemanticsLabel('Add attachment or action'));
    await tester.pumpAndSettle();
    expect(find.text('Add to chat'), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-plus-file')), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-plus-photo')), findsOneWidget);
    // Connectors has no route in the composer, so it is not offered dead.
    expect(
      find.byKey(const ValueKey('composer-plus-connectors')),
      findsNothing,
    );

    final photo = find.byKey(const ValueKey('composer-plus-photo'));
    await tester.ensureVisible(photo);
    await tester.pumpAndSettle();
    await tester.tap(photo);
    await tester.pumpAndSettle();

    expect(images, ['image']);
    expect(files, isEmpty);
    expect(find.text('shot.png'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Add attachment or action'));
    await tester.pumpAndSettle();
    final file = find.byKey(const ValueKey('composer-plus-file'));
    await tester.ensureVisible(file);
    await tester.pumpAndSettle();
    await tester.tap(file);
    await tester.pumpAndSettle();

    expect(files, ['file']);
    expect(find.text('brief.md'), findsOneWidget);
  });

  testWidgets('send stays disabled for whitespace and Enter sends the draft', (
    tester,
  ) async {
    String? sent;
    await tester.pumpWidget(
      _app(
        V2ChatPage(data: const V2ChatPageData(), onSend: (text) => sent = text),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    expect(sent, isNull, reason: 'whitespace is not a message');

    await tester.enterText(find.byType(TextField), 'Build the header');
    await tester.pump();
    await tester.showKeyboard(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(sent, 'Build the header');
  });

  testWidgets('Shift+Enter inserts a newline instead of sending', (
    tester,
  ) async {
    String? sent;
    await tester.pumpWidget(
      _app(
        V2ChatPage(data: const V2ChatPageData(), onSend: (text) => sent = text),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(find.byType(TextField), 'line one');
    await tester.pump();
    await tester.showKeyboard(find.byType(TextField));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(sent, isNull, reason: 'Shift+Enter must not send');
    final field = tester.widget<TextField>(find.byType(TextField));
    // The field keeps its multiline action, so the newline is inserted by the
    // text input itself rather than by a key handler.
    expect(field.controller!.text, 'line one');
    expect(field.textInputAction, TextInputAction.newline);
  });

  testWidgets('Stop dispatches the queued message and dismiss removes it', (
    tester,
  ) async {
    var stops = 0;
    var dismisses = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(
            state: V2ChatState.running,
            queuedCount: 1,
          ),
          onStop: () => stops++,
          onDismissQueued: () => dismisses++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('1 queued'), findsOneWidget);

    await tester.tap(find.text('Send now'));
    await tester.pump();
    expect(stops, 1, reason: 'Send now dispatches through the host stop path');

    await tester.tap(
      find.descendant(
        of: find.byType(V2QueueDock),
        matching: find.byIcon(Icons.close_rounded),
      ),
    );
    await tester.pump();
    expect(dismisses, 1);
  });

  // ── Wiring ────────────────────────────────────────────────────────────────

  testWidgets('every control on the wired screen reaches its owner', (
    tester,
  ) async {
    final taps = <String, int>{};
    void hit(String name) => taps[name] = (taps[name] ?? 0) + 1;
    String? sent;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          onMenu: () => hit('menu'),
          onModelChipTap: () => hit('model'),
          onStudio: () => hit('studio'),
          onBrowser: () => hit('browser'),
          onMore: () => hit('more'),
          onSuggestionTap: (_) => hit('suggestion'),
          onPlus: () => hit('plus'),
          onPermissionTap: () => hit('permission'),
          onMic: () => hit('mic'),
          onSend: (text) => sent = text,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    for (final label in [
      'Open menu',
      'Open Studio',
      'Open Browser',
      'More options',
      'Add attachment or action',
      'Voice input',
    ]) {
      await tester.tap(find.bySemanticsLabel(label));
    }
    await tester.tap(find.text('Auto'));
    await tester.tap(find.text('Build a landing page'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Permission: General. Change'));
    await tester.enterText(find.byType(TextField), 'Ship it');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Send'));
    await tester.pump();

    expect(taps, <String, int>{
      'menu': 1,
      'model': 1,
      'studio': 1,
      'browser': 1,
      'more': 1,
      'suggestion': 1,
      'plus': 1,
      'permission': 1,
      'mic': 1,
    });
    expect(sent, 'Ship it');
  });

  testWidgets('a state never draws an action it cannot honour', (tester) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      _app(
        const V2ChatPage(
          data: V2ChatPageData(state: V2ChatState.planLimited),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Daily limit reached'), findsOneWidget);
    expect(find.text('See plans'), findsNothing);

    await tester.pumpWidget(
      _app(const V2ChatPage(data: V2ChatPageData(state: V2ChatState.error))),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text("Couldn't load this chat."), findsOneWidget);
    expect(find.text('Try again'), findsNothing);

    await tester.pumpWidget(
      _app(const V2ChatPage(data: V2ChatPageData(state: V2ChatState.offline))),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text("You're offline"), findsOneWidget);
    expect(find.widgetWithText(OButton, 'Retry'), findsNothing);

    await tester.pumpWidget(
      _app(const V2ChatPage(data: V2ChatPageData(state: V2ChatState.running))),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Ovid is working'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Stop')),
      isSemantics(
        label: 'Stop',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    handle.dispose();
  });

  // ── Text budget ───────────────────────────────────────────────────────────

  test('copy fits the text budget', () {
    int words(String value) => value.trim().split(RegExp(r'\s+')).length;
    const data = V2ChatPageData();

    expect(words(data.headline), lessThanOrEqualTo(4));
    expect(data.suggestions, hasLength(3));
    for (final row in data.suggestions) {
      expect(words(row.title), lessThanOrEqualTo(4), reason: row.title);
    }
    for (final label in ['See plans', 'Try again', 'Retry', 'Send now']) {
      expect(words(label), lessThanOrEqualTo(3), reason: label);
    }
    // One question, no paragraph: the empty state is a greeting, not an
    // explainer.
    expect(data.headline, isNot(contains('.')));
  });

  // ── Responsive ────────────────────────────────────────────────────────────

  for (final width in <double>[320, 360, 412, 600, 900, 1280]) {
    for (final scale in <double>[1, 2]) {
      for (final dark in [false, true]) {
        testWidgets(
          'fits ${width.toInt()} dp at ${scale}x (${dark ? 'dark' : 'light'})',
          (tester) async {
            tester.view.physicalSize = Size(width, 800);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);

            Widget page(V2ChatState state) => MaterialApp(
              theme: dark ? OTheme.dark() : OTheme.light(),
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 800),
                  textScaler: TextScaler.linear(scale),
                ),
                child: V2ChatPage(
                  data: V2ChatPageData(state: state, queuedCount: 2),
                  onMenu: _noop,
                  onModelChipTap: _noop,
                  onStudio: _noop,
                  onBrowser: _noop,
                  onMore: _noop,
                  onSuggestionTap: _ignoreSuggestion,
                  onPlus: _noop,
                  onPermissionTap: _noop,
                  onMic: _noop,
                  onSend: _ignoreText,
                  onStop: _noop,
                  onRetry: _noop,
                  onSeePlans: _noop,
                  onDismissQueued: _noop,
                  onSendQueuedNow: _noop,
                ),
              ),
            );

            for (final state in V2ChatState.values) {
              await tester.pumpWidget(page(state));
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 400));
              expect(
                tester.takeException(),
                isNull,
                reason: '$state overflowed at ${width.toInt()} dp / ${scale}x',
              );
            }

            // Above the tablet breakpoint the column centres and stops at 720
            // instead of stretching the phone layout across the window.
            await tester.pumpWidget(page(V2ChatState.empty));
            await tester.pump(const Duration(milliseconds: 400));
            final scroll = find
                .ancestor(
                  of: find.text('What should we build?'),
                  matching: find.byType(SingleChildScrollView),
                )
                .first;
            expect(tester.getSize(scroll).width, lessThanOrEqualTo(720));
            if (width > 720) {
              expect(tester.getCenter(scroll).dx, closeTo(width / 2, 1));
            }
          },
        );
      }
    }
  }

  // ── Keyboard ──────────────────────────────────────────────────────────────

  testWidgets('the field stays above the keyboard', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(
      _app(V2ChatPage(data: const V2ChatPageData(), onSend: _ignoreText)),
    );
    await tester.pump(const Duration(milliseconds: 400));

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();

    final field = tester.getRect(find.byType(TextField));
    expect(
      field.bottom,
      lessThanOrEqualTo(740 - 300),
      reason: 'the composer must sit above the keyboard inset',
    );
    expect(field.top, greaterThanOrEqualTo(56));
  });

  testWidgets('focus survives a host rebuild', (tester) async {
    const data = V2ChatPageData();
    await tester.pumpWidget(
      _app(V2ChatPage(data: data, onSend: _ignoreText)),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byType(TextField));
    await tester.pump();
    final node = tester.widget<TextField>(find.byType(TextField)).focusNode!;
    expect(node.hasFocus, isTrue);

    // A new data instance (the shell rebuilds on every app-state change) must
    // not swap the focus node or close the keyboard.
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: data.copyWithSendError(null),
          onSend: _ignoreText,
        ),
      ),
    );
    await tester.pump();

    expect(tester.widget<TextField>(find.byType(TextField)).focusNode, same(node));
    expect(node.hasFocus, isTrue);
  });

  // ── Semantics ─────────────────────────────────────────────────────────────

  testWidgets('icon buttons are labelled and suggestion rows are buttons', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          onMenu: _noop,
          onModelChipTap: _noop,
          onStudio: _noop,
          onBrowser: _noop,
          onMore: _noop,
          onSuggestionTap: _ignoreSuggestion,
          onPlus: _noop,
          onPermissionTap: _noop,
          onMic: _noop,
          onSend: _ignoreText,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    for (final label in [
      'Open menu',
      'Open Studio',
      'Open Browser',
      'More options',
      'Add attachment or action',
      'Voice input',
      'Send',
    ]) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
    }

    expect(
      tester.getSemantics(find.bySemanticsLabel('Build a landing page')),
      isSemantics(
        label: 'Build a landing page',
        isButton: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('TalkBack reads top bar, then body, then composer', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          onMenu: _noop,
          onModelChipTap: _noop,
          onStudio: _noop,
          onBrowser: _noop,
          onMore: _noop,
          onSuggestionTap: _ignoreSuggestion,
          onPlus: _noop,
          onPermissionTap: _noop,
          onMic: _noop,
          onSend: _ignoreText,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    final labels = _readingOrder(tester);
    const anchors = [
      'Ovid Si',
      'What should we build?',
      'Build a landing page',
      'Add attachment or action',
      'Send',
    ];
    final indices = [for (final anchor in anchors) labels.indexOf(anchor)];
    expect(indices, everyElement(isNonNegative), reason: labels.join(' | '));
    for (var i = 1; i < indices.length; i++) {
      expect(
        indices[i],
        greaterThan(indices[i - 1]),
        reason: '${anchors[i]} must read after ${anchors[i - 1]}: '
            '${labels.join(' | ')}',
      );
    }
    handle.dispose();
  });

  // ── Motion ────────────────────────────────────────────────────────────────

  testWidgets('the entrance budget is 200 ms and nothing loops while idle', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const V2ChatPage(data: V2ChatPageData())));
    await tester.pump();

    final slide = tester.widget<OFadeSlide>(find.byType(OFadeSlide).first);
    expect(slide.duration, isNotNull);
    expect(
      slide.duration!,
      lessThanOrEqualTo(const Duration(milliseconds: 200)),
      reason: 'an entrance may not run longer than 200 ms',
    );

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(
      tester.binding.transientCallbackCount,
      isZero,
      reason: 'the entrance leaves no ticker behind',
    );

    await tester.pump(const Duration(seconds: 2));
    expect(
      tester.binding.transientCallbackCount,
      isZero,
      reason: 'nothing loops while the screen is idle',
    );
  });

  testWidgets('reduced motion removes the entrance and the working pulse', (
    tester,
  ) async {
    Widget page(V2ChatState state) => MaterialApp(
      theme: OTheme.light(),
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(800, 600),
          disableAnimations: true,
        ),
        child: V2ChatPage(
          data: V2ChatPageData(state: state),
          onStop: _noop,
        ),
      ),
    );

    await tester.pumpWidget(page(V2ChatState.empty));
    await tester.pump();
    // The entrance helper hands its child straight through: no opacity ramp,
    // no slide, no switcher.
    expect(
      find.descendant(
        of: find.byType(OFadeSlide),
        matching: find.byType(AnimatedSlide),
      ),
      findsNothing,
    );
    expect(find.byType(AnimatedSwitcher), findsNothing);

    await tester.pumpWidget(page(V2ChatState.running));
    await tester.pump();
    // The working dot is static: the pulse never wraps itself in a fade.
    expect(find.byType(OPulse), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(OPulse),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );

    // Whatever the text field schedules while it updates is one-shot: the
    // screen settles and stays settled.
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.binding.transientCallbackCount, isZero);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.transientCallbackCount, isZero);
  });
}

void _noop() {}

void _ignoreText(String _) {}

void _ignoreSuggestion(V2ChatSuggestion _) {}

/// Semantics in the order the platform receives it: children are sorted by
/// their [SemanticsSortKey] within contiguous compatible groups.
List<String> _readingOrder(WidgetTester tester) {
  final root = tester
      .binding
      .renderViews
      .first
      .owner
      ?.semanticsOwner
      ?.rootSemanticsNode;
  final nodes = <SemanticsNode>[];
  if (root != null) _flattenOrdered(root, nodes);
  return [
    for (final node in nodes)
      if (node.getSemanticsData().label.trim().isNotEmpty)
        node.getSemanticsData().label.trim(),
  ];
}

void _flattenOrdered(SemanticsNode node, List<SemanticsNode> out) {
  out.add(node);
  final children = <SemanticsNode>[];
  node.visitChildren((child) {
    children.add(child);
    return true;
  });
  var start = 0;
  while (start < children.length) {
    final key = children[start].sortKey;
    var end = start + 1;
    while (end < children.length) {
      final other = children[end].sortKey;
      if (other.runtimeType != key.runtimeType) break;
      if (key != null && other?.name != key.name) break;
      end++;
    }
    final group = children.sublist(start, end);
    if (key != null) {
      group.sort((a, b) => a.sortKey!.compareTo(b.sortKey!));
    }
    for (final child in group) {
      _flattenOrdered(child, out);
    }
    start = end;
  }
}
