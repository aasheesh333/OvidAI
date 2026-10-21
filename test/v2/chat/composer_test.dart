import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/composer_attachments.dart';
import 'package:ovid_ai/ui/v2/chat/composer_mentions.dart';
import 'package:ovid_ai/ui/v2/chat/composer_voice.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';

Widget _app(Widget home, {bool dark = false, double textScale = 1}) =>
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    );

final _mentions = V2StaticMentionSource(
  sessions: const [
    V2MentionCandidate.session(
      id: 's1',
      title: 'Portfolio redesign',
      subtitle: 'Auto',
    ),
    V2MentionCandidate.session(
      id: 's2',
      title: 'Fix login bug',
      subtitle: 'Ovid Pro',
    ),
    V2MentionCandidate.session(
      id: 's3',
      title: 'Landing page copy',
      subtitle: 'Auto',
    ),
    V2MentionCandidate.session(
      id: 's4',
      title: 'Pricing experiments',
      subtitle: 'Auto',
    ),
    V2MentionCandidate.session(
      id: 's5',
      title: 'Release notes',
      subtitle: 'Auto',
    ),
  ],
  projects: const [
    V2MentionCandidate.project(
      id: 'p1',
      title: 'Website refresh',
      subtitle: 'Project · 2 chats',
    ),
  ],
);

class _FakePicker {
  _FakePicker(this.results);

  final List<List<V2ComposerAttachment>?> results;
  int calls = 0;

  Future<List<V2ComposerAttachment>?> pick() async {
    final index = calls < results.length ? calls : results.length - 1;
    calls++;
    return results[index];
  }
}

class _FakeVoice implements V2VoiceService {
  bool available = true;
  bool permitted = true;
  int starts = 0;
  int stops = 0;
  String? localeId;
  void Function(String text, bool isFinal)? _onResult;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> ensureMicrophonePermission() async => permitted;

  @override
  Future<bool> start(
    void Function(String text, bool isFinal) onResult, {
    String? localeId,
  }) async {
    starts++;
    this.localeId = localeId;
    _onResult = onResult;
    return true;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> cancel() async {
    stops++;
  }

  void emit(String text, {bool finalResult = false}) {
    _onResult?.call(text, finalResult);
  }
}


/// Opens the composer's "+" menu and taps the File row.
Future<void> _pickFile(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('Add attachment or action'));
  await tester.pumpAndSettle();
  final row = find.byKey(const ValueKey('composer-plus-file'));
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}

V2ComposerAttachment _file(String name, {int size = 14540, String? path}) =>
    V2ComposerAttachment(name: name, path: path ?? '/tmp/$name', size: size);

void main() {
  group('mention token parsing', () {
    test('detects the token under the caret only at a word boundary', () {
      expect(v2ActiveMentionAt('hello @por', 10)?.query, 'por');
      expect(v2ActiveMentionAt('hello @por', 10)?.start, 6);
      expect(v2ActiveMentionAt('@', 1)?.query, '');
      expect(v2ActiveMentionAt('mail me@host', 12), isNull);
      expect(v2ActiveMentionAt('hello @por ', 11), isNull);
      expect(
        v2ActiveMention('hello @', const TextSelection.collapsed(offset: 7)),
        isNotNull,
      );
      expect(
        v2ActiveMention(
          'hello @por',
          const TextSelection(baseOffset: 6, extentOffset: 10),
        ),
        isNull,
      );
    });

    test('caps suggestions at five and searches by title', () {
      final rows = _mentions.search('', limit: 5);
      expect(rows, hasLength(5));
      expect(
        rows.where((row) => row.kind == V2MentionKind.project),
        hasLength(1),
      );

      final filtered = _mentions.search('fix', limit: 5);
      expect(filtered.single.title, 'Fix login bug');
    });

    test('@project: searches projects only', () {
      final rows = _mentions.search('project:web', limit: 5);
      expect(rows, hasLength(1));
      expect(rows.single.id, 'p1');
      expect(rows.single.token, '@project:p1 ');
      expect(_mentions.search('project:port', limit: 5), isEmpty);
    });

    test('resolves picked and typed titles to session ids', () {
      final picked = v2MentionRefsIn(
        'compare @[Portfolio redesign] with @[Fix login bug]',
        source: _mentions,
        pickedSessionIds: const {'portfolio redesign': 's1'},
      );
      expect(picked.sessionRefs, ['s1', 's2']);

      final typed = v2MentionRefsIn(
        '@[Fix login bug] and @project:p1 and @session:s3',
        source: _mentions,
        currentSessionId: 's1',
      );
      expect(typed.sessionRefs, ['s3', 's2']);
      expect(typed.projectRefs, ['p1']);
    });

    test('inserted tokens round-trip through the host parser', () {
      const chat = V2MentionCandidate.session(
        id: 's2',
        title: 'Fix login bug',
        subtitle: 'Auto',
      );
      const project = V2MentionCandidate.project(
        id: 'p1',
        title: 'Website refresh',
      );

      // The source deliberately cannot resolve titles: only the token text and
      // the picker's own id map are available, exactly like a rename after the
      // menu inserted the token.
      final refs = v2MentionRefsIn(
        '${chat.token}compare with ${project.token}',
        source: const V2EmptyMentionSource(),
        pickedSessionIds: const {'fix login bug': 's2'},
      );
      expect(chat.token, '@[Fix login bug] ');
      expect(project.token, '@project:p1 ');
      expect(refs.sessionRefs, ['s2']);
      expect(refs.projectRefs, ['p1']);
    });

    test('the host resolver maps local ids to the ids the gateway takes', () {
      v2SessionRefResolver = (id) => id == 'local-1' ? 'srv-1' : id;
      addTearDown(() => v2SessionRefResolver = null);

      final refs = v2MentionRefsIn(
        '@[Portfolio redesign]',
        source: const V2EmptyMentionSource(),
        pickedSessionIds: const {'portfolio redesign': 'local-1'},
      );
      expect(refs.sessionRefs, ['srv-1']);
    });
  });

  group('attachment rules', () {
    test('rejects oversized, unsupported and unreadable files', () {
      expect(
        V2AttachmentRules.rejectionFor(
          _file('huge.pdf', size: V2AttachmentRules.maxBytes + 1),
        ),
        contains('larger than 8 MB'),
      );
      expect(
        V2AttachmentRules.rejectionFor(_file('setup.exe')),
        contains('not supported'),
      );
      expect(
        V2AttachmentRules.rejectionFor(_file('notes.txt', path: '')),
        contains('Could not read'),
      );
      expect(V2AttachmentRules.rejectionFor(_file('notes.txt')), isNull);
    });

    test('stages at most five unique files', () {
      final existing = [_file('one.txt')];
      final batch = V2AttachmentRules.accept(
        existing: existing,
        incoming: [
          _file('one.txt'),
          _file('two.txt'),
          _file('three.txt'),
          _file('four.txt'),
          _file('five.txt'),
          _file('six.txt'),
        ],
      );
      expect(batch.accepted, hasLength(4));
      expect(batch.rejected, contains('one.txt is already attached.'));
      expect(batch.rejected, contains('You can attach up to 5 files.'));
    });

    test('8 MB is the inclusive ceiling', () {
      expect(
        V2AttachmentRules.rejectionFor(
          _file('exact.pdf', size: V2AttachmentRules.maxBytes),
        ),
        isNull,
      );
      expect(
        V2AttachmentRules.rejectionFor(
          _file('over.pdf', size: V2AttachmentRules.maxBytes + 1),
        ),
        contains('larger than 8 MB'),
      );
    });
  });

  group('voice locales', () {
    test('maps Hindi, Hinglish, Punjabi and Tamil', () {
      expect(V2VoiceLocales.localeFor('hi'), 'hi-IN');
      expect(V2VoiceLocales.localeFor('hinglish'), 'hi-IN');
      expect(V2VoiceLocales.localeFor('pa'), 'pa-IN');
      expect(V2VoiceLocales.localeFor('ta'), 'ta-IN');
      expect(V2VoiceLocales.localeFor('xx'), 'en-IN');
    });
  });

  testWidgets('@ opens, filters and inserts a chat mention in empty chat', (
    tester,
  ) async {
    V2ComposerSubmission? sent;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(sessionId: 'current'),
          mentionSource: _mentions,
          onSubmit: (submission) => sent = submission,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(find.byType(TextField), '@');
    await tester.pump();

    expect(find.byType(V2MentionSuggestions), findsOneWidget);
    expect(find.text('Portfolio redesign'), findsOneWidget);
    expect(find.text('Fix login bug'), findsOneWidget);
    expect(find.text('Website refresh'), findsOneWidget);
    expect(find.text('Release notes'), findsNothing);

    await tester.enterText(find.byType(TextField), '@fix');
    await tester.pump();

    expect(find.text('Fix login bug'), findsOneWidget);
    expect(find.text('Portfolio redesign'), findsNothing);
    expect(find.text('Website refresh'), findsNothing);

    await tester.tap(find.text('Fix login bug'));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '@[Fix login bug] ');
    expect(find.byType(V2MentionSuggestions), findsNothing);

    await tester.enterText(
      find.byType(TextField),
      '@[Fix login bug] compare the header',
    );
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();

    expect(sent, isNotNull);
    expect(sent!.text, '@[Fix login bug] compare the header');
    expect(sent!.sessionRefs, ['s2']);
  });

  testWidgets('@project: inserts a project reference', (tester) async {
    V2ComposerSubmission? sent;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          mentionSource: _mentions,
          onSubmit: (submission) => sent = submission,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(find.byType(TextField), '@project:');
    await tester.pump();

    expect(find.text('Website refresh'), findsOneWidget);
    expect(find.text('Portfolio redesign'), findsNothing);

    await tester.tap(find.text('Website refresh'));
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '@project:p1 ');

    await tester.enterText(find.byType(TextField), '@project:p1 summarize');
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();

    expect(sent!.projectRefs, ['p1']);
    expect(sent!.sessionRefs, isEmpty);
  });

  testWidgets('mentions work in a live chat and are 48 dp tall', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    V2ComposerSubmission? sent;
    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: const V2LiveChatData(
            sessionId: 'live',
            items: [V2LiveUserMessage(id: 'u1', text: 'Build the header')],
          ),
          mentionSource: _mentions,
          onSubmit: (submission) => sent = submission,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(find.byType(TextField), '@');
    await tester.pump();

    final row = find.byKey(const ValueKey('mention-session-s1'));
    expect(row, findsOneWidget);
    expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
    expect(
      find.bySemanticsLabel('Mention Portfolio redesign. Auto'),
      findsOneWidget,
    );

    await tester.tap(find.text('Portfolio redesign'));
    await tester.pump();
    await tester.enterText(
      find.byType(TextField),
      '@[Portfolio redesign] match this style',
    );
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();

    expect(sent!.sessionRefs, ['s1']);
    handle.dispose();
  });

  testWidgets('attachments add, show name and size, and remove', (
    tester,
  ) async {
    final picker = _FakePicker([
      [_file('report.pdf')],
    ]);
    await tester.pumpWidget(
      _app(
        V2ChatPage(data: const V2ChatPageData(), attachmentPicker: picker.pick),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await _pickFile(tester);

    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('14.2 KB'), findsOneWidget);
    final remove = find.byTooltip('Remove report.pdf');
    expect(remove, findsOneWidget);
    expect(tester.getSize(remove).height, greaterThanOrEqualTo(48));

    await tester.tap(remove);
    await tester.pump();

    expect(find.text('report.pdf'), findsNothing);
  });

  testWidgets('attachment limit stops at five and explains why', (
    tester,
  ) async {
    final picker = _FakePicker([
      [
        _file('one.txt'),
        _file('two.txt'),
        _file('three.txt'),
        _file('four.txt'),
        _file('five.txt'),
        _file('six.txt'),
      ],
    ]);
    await tester.pumpWidget(
      _app(
        V2ChatPage(data: const V2ChatPageData(), attachmentPicker: picker.pick),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await _pickFile(tester);
    expect(find.text('You can attach up to 5 files.'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip && (widget.message ?? '').startsWith('Remove '),
      ),
      findsNWidgets(5),
    );
  });

  testWidgets('unsupported and oversized files are rejected clearly', (
    tester,
  ) async {
    final picker = _FakePicker([
      [_file('setup.exe')],
      [_file('huge.pdf', size: V2AttachmentRules.maxBytes + 1)],
    ]);
    await tester.pumpWidget(
      _app(
        V2ChatPage(data: const V2ChatPageData(), attachmentPicker: picker.pick),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await _pickFile(tester);
    expect(
      find.text('setup.exe: that file type is not supported.'),
      findsOneWidget,
    );

    await _pickFile(tester);
    expect(find.text('huge.pdf is larger than 8 MB.'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip && (widget.message ?? '').startsWith('Remove '),
      ),
      findsNothing,
      reason: 'the rejected file is never staged',
    );
  });

  testWidgets('a picker failure shows an error instead of dropping silently', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          attachmentPicker: () async => throw StateError('permission denied'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await _pickFile(tester);

    expect(
      find.text('Could not open the file picker. Try again.'),
      findsOneWidget,
    );
  });

  testWidgets('send carries staged attachments and mention refs', (
    tester,
  ) async {
    final picker = _FakePicker([
      [_file('brief.md', size: 2048), _file('shot.png', size: 4096)],
    ]);
    V2ComposerSubmission? sent;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          mentionSource: _mentions,
          attachmentPicker: picker.pick,
          onSubmit: (submission) => sent = submission,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await _pickFile(tester);
    await tester.enterText(find.byType(TextField), '@por');
    await tester.pump();
    await tester.tap(find.text('Portfolio redesign'));
    await tester.pump();
    await tester.enterText(
      find.byType(TextField),
      '@[Portfolio redesign] use the brief',
    );
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();

    expect(sent, isNotNull);
    expect(sent!.attachments, hasLength(2));
    expect(sent!.attachments.first.name, 'brief.md');
    expect(sent!.attachments.first.path, '/tmp/brief.md');
    expect(sent!.attachments.first.size, 2048);
    expect(sent!.runTaskAttachments.first, (
      name: 'brief.md',
      path: '/tmp/brief.md',
      size: 2048,
    ));
    expect(sent!.sessionRefs, ['s1']);
    expect(find.text('brief.md'), findsNothing);
  });

  testWidgets('voice starts with the selected locale, streams and stops', (
    tester,
  ) async {
    final voice = _FakeVoice();
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          voiceService: voice,
          voiceLanguage: 'hinglish',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.bySemanticsLabel('Voice input'));
    await tester.pumpAndSettle();

    expect(voice.starts, 1);
    expect(voice.localeId, 'hi-IN');
    expect(find.bySemanticsLabel('Stop voice input'), findsOneWidget);

    voice.emit('mujhe');
    await tester.pump();
    voice.emit('mujhe ek landing page chahiye');
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'mujhe ek landing page chahiye');

    await tester.tap(find.bySemanticsLabel('Stop voice input'));
    await tester.pumpAndSettle();

    expect(voice.stops, 1);
    expect(field.controller!.text, 'mujhe ek landing page chahiye');
    expect(find.bySemanticsLabel('Voice input'), findsOneWidget);
  });

  testWidgets('voice permission denial shows a clear error', (tester) async {
    final voice = _FakeVoice()..permitted = false;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          voiceService: voice,
          voiceLanguage: 'pa',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.bySemanticsLabel('Voice input'));
    await tester.pumpAndSettle();

    expect(voice.starts, 0);
    expect(find.text(V2VoiceDictation.permissionDeniedMessage), findsOneWidget);
    expect(find.bySemanticsLabel('Voice input'), findsOneWidget);
  });

  testWidgets('sending stops dictation and keeps the transcript', (
    tester,
  ) async {
    final voice = _FakeVoice();
    V2ComposerSubmission? sent;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          voiceService: voice,
          voiceLanguage: 'ta',
          onSubmit: (submission) => sent = submission,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.bySemanticsLabel('Voice input'));
    await tester.pumpAndSettle();
    voice.emit('oru landing page venum');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(voice.stops, 1);
    expect(sent!.text, 'oru landing page venum');
  });

  testWidgets('voice starts and stops in the live chat composer', (
    tester,
  ) async {
    final voice = _FakeVoice();
    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: const V2LiveChatData(
            items: [V2LiveUserMessage(id: 'u1', text: 'Hi')],
          ),
          voiceService: voice,
          voiceLanguage: 'hi',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.bySemanticsLabel('Voice input'));
    await tester.pumpAndSettle();
    expect(voice.localeId, 'hi-IN');

    voice.emit('नमस्ते', finalResult: true);
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'नमस्ते');
    expect(find.bySemanticsLabel('Voice input'), findsOneWidget);
  });

  testWidgets('disposing while dictating cancels without errors', (
    tester,
  ) async {
    final voice = _FakeVoice();
    await tester.pumpWidget(
      _app(V2ChatPage(data: const V2ChatPageData(), voiceService: voice)),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.bySemanticsLabel('Voice input'));
    await tester.pumpAndSettle();
    expect(voice.starts, 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    expect(voice.stops, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('draft survives a rebuild without data changes', (tester) async {
    var changes = 0;
    Widget build() => _app(
      V2ChatPage(
        data: const V2ChatPageData(),
        onDraftChanged: (_) => changes++,
      ),
    );
    await tester.pumpWidget(build());
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(find.byType(TextField), 'Keep this draft');
    await tester.pump();
    await tester.pumpWidget(build());
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Keep this draft');
    expect(changes, 1);
  });

  for (final dark in [false, true]) {
    testWidgets('composer with mentions open fits 320 dp at 200 % text '
        '(${dark ? 'dark' : 'light'})', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final voice = _FakeVoice()..permitted = false;

      await tester.pumpWidget(
        _app(
          V2ChatPage(
            data: const V2ChatPageData(),
            mentionSource: _mentions,
            voiceService: voice,
            voiceLanguage: 'pa',
          ),
          dark: dark,
          textScale: 2,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.bySemanticsLabel('Voice input'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '@');
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(V2MentionSuggestions), findsOneWidget);
      expect(find.bySemanticsLabel('Send'), findsOneWidget);
    });
  }

  testWidgets('attachment chips and mentions fit 320 dp at 200 % text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final picker = _FakePicker([
      [
        _file('a-very-long-attachment-name-that-needs-ellipsis.pdf'),
        _file('two.txt'),
      ],
    ]);
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          mentionSource: _mentions,
          attachmentPicker: picker.pick,
        ),
        textScale: 2,
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await _pickFile(tester);
    await tester.enterText(find.byType(TextField), '@');
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(V2MentionSuggestions), findsOneWidget);
    expect(find.text('two.txt'), findsOneWidget);
  });

  testWidgets('live composer with mentions open fits 320 dp at 200 % text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: const V2LiveChatData(
            items: [V2LiveUserMessage(id: 'u1', text: 'Hi')],
          ),
          mentionSource: _mentions,
        ),
        textScale: 2,
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(find.byType(TextField), '@');
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(V2MentionSuggestions), findsOneWidget);
  });
}
