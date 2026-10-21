import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/voice_reply_card.dart';

Widget _app(
  Widget home, {
  bool dark = false,
  double textScale = 1,
  bool reducedMotion = false,
}) => MaterialApp(
  theme: dark ? OTheme.dark() : OTheme.light(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: reducedMotion,
    ),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: home),
  ),
);

const _data = V2VoiceReplyData(
  title: 'Your portfolio is ready',
  subtitle: 'Vortex Studio opens with a dark hero and four project cards.',
  metrics: [
    V2VoiceMetric(label: 'Projects', value: '4'),
    V2VoiceMetric(label: 'Load time', value: '0.8 s'),
    V2VoiceMetric(label: 'Contrast', value: 'AAA'),
  ],
  actionLabel: 'Open preview',
  transcript: 'I built the portfolio you asked for. It is ready to preview.',
  duration: Duration(seconds: 12),
  position: Duration(seconds: 3),
);

void main() {
  testWidgets('renders the voice note and its visual card', (tester) async {
    await tester.pumpWidget(_app(const V2VoiceReplyCard(data: _data)));

    expect(find.text('Your portfolio is ready'), findsOneWidget);
    expect(
      find.text('Vortex Studio opens with a dark hero and four project cards.'),
      findsOneWidget,
    );
    expect(find.text('4'), findsOneWidget);
    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('0.8 s'), findsOneWidget);
    expect(find.text('AAA'), findsOneWidget);
    expect(find.text('0:03 / 0:12'), findsOneWidget);
    expect(find.text('Open preview'), findsOneWidget);
    expect(find.text('Show transcript'), findsOneWidget);
    expect(find.bySemanticsLabel('Play voice reply'), findsOneWidget);
    expect(
      find.text('I built the portfolio you asked for. It is ready to preview.'),
      findsNothing,
    );
  });

  testWidgets('play button reports taps and reflects playing state', (
    tester,
  ) async {
    var plays = 0;
    await tester.pumpWidget(
      _app(V2VoiceReplyCard(data: _data, onPlay: () => plays++)),
    );

    await tester.tap(find.bySemanticsLabel('Play voice reply'));
    expect(plays, 1);

    await tester.pumpWidget(
      _app(
        V2VoiceReplyCard(
          data: const V2VoiceReplyData(
            title: 'Playing now',
            duration: Duration(seconds: 12),
            position: Duration(seconds: 3),
            playing: true,
          ),
          onPlay: () => plays++,
        ),
      ),
    );
    expect(find.bySemanticsLabel('Pause voice reply'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Pause voice reply'));
    expect(plays, 2);
  });

  testWidgets('waveform seeks to the tapped fraction', (tester) async {
    Duration? sought;
    await tester.pumpWidget(
      _app(
        V2VoiceReplyCard(data: _data, onSeek: (position) => sought = position),
      ),
    );

    final waveform = find.byKey(const ValueKey('voice-reply-waveform'));
    expect(waveform, findsOneWidget);
    await tester.tapAt(tester.getCenter(waveform));

    expect(sought, isNotNull);
    expect(sought!.inMilliseconds, inInclusiveRange(5600, 6400));
  });

  testWidgets('transcript toggle requests the next state', (tester) async {
    bool? requested;
    await tester.pumpWidget(
      _app(
        V2VoiceReplyCard(
          data: _data,
          onToggleTranscript: (expanded) => requested = expanded,
        ),
      ),
    );

    await tester.tap(find.text('Show transcript'));
    expect(requested, isTrue);
    expect(
      find.text('I built the portfolio you asked for. It is ready to preview.'),
      findsNothing,
    );

    await tester.pumpWidget(
      _app(
        V2VoiceReplyCard(
          data: _data,
          transcriptExpanded: true,
          onToggleTranscript: (expanded) => requested = expanded,
        ),
      ),
    );
    expect(find.text('Hide transcript'), findsOneWidget);
    expect(
      find.text('I built the portfolio you asked for. It is ready to preview.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Hide transcript'));
    expect(requested, isFalse);
  });

  testWidgets('action button fires', (tester) async {
    var opens = 0;
    await tester.pumpWidget(
      _app(V2VoiceReplyCard(data: _data, onOpenAction: () => opens++)),
    );

    await tester.tap(find.text('Open preview'));
    expect(opens, 1);
  });

  testWidgets('duration labels are compact and stable', (tester) async {
    expect(formatVoiceDuration(const Duration(seconds: 12)), '0:12');
    expect(formatVoiceDuration(const Duration(seconds: 61)), '1:01');
    expect(formatVoiceDuration(const Duration(seconds: 3661)), '1:01:01');
    expect(formatVoiceDuration(const Duration(seconds: -4)), '0:00');
  });

  testWidgets('lays out at 320 dp with 200 % text in light and dark', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final dark in [false, true]) {
      await tester.pumpWidget(
        _app(
          V2VoiceReplyCard(
            data: _data,
            transcriptExpanded: true,
            onPlay: () {},
            onSeek: (_) {},
            onOpenAction: () {},
            onToggleTranscript: (_) {},
          ),
          dark: dark,
          textScale: 2,
        ),
      );
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason: 'overflow at 320 dp / 200 % text (${dark ? 'dark' : 'light'})',
      );
      expect(find.text('Your portfolio is ready'), findsOneWidget);
      expect(find.text('Open preview'), findsOneWidget);
    }
  });
}
