import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/static_rich_content.dart';

const List<int> _tinyPng = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('static SVG sanitizer', () {
    test('active SVG is rejected instead of rasterized', () {
      expect(
        () =>
            sanitizeStaticSvg('<svg onload="fetch(1)"><foreignObject/></svg>'),
        throwsFormatException,
      );
    });

    test('script and executable-container elements fail closed', () {
      const attacks = <String>[
        '<svg><script>alert(1)</script></svg>',
        '<svg><SCRIPT href="https://evil.test/x.js"/></svg>',
        '<svg><foreignObject><body>HTML</body></foreignObject></svg>',
        '<svg><iframe src="https://evil.test"/></svg>',
        '<svg><object data="data:text/html,evil"/></svg>',
        '<svg><embed src="https://evil.test"/></svg>',
        '<svg><handler>alert(1)</handler></svg>',
      ];
      for (final attack in attacks) {
        expect(
          () => sanitizeStaticSvg(attack),
          throwsFormatException,
          reason: attack,
        );
      }
    });

    test('namespace and event-attribute bypasses fail closed', () {
      const attacks = <String>[
        '<svg xmlns="urn:evil"><rect/></svg>',
        '<s:svg xmlns:s="http://www.w3.org/2000/svg"><s:rect/></s:svg>',
        '<svg xmlns:xlink="http://www.w3.org/1999/xlink"><a xlink:href="javascript:alert(1)">x</a></svg>',
        '<svg xmlns:ev="http://www.w3.org/2001/xml-events" ev:event="load"><rect/></svg>',
        '<svg ONLOAD="alert(1)"><rect/></svg>',
        '<svg><rect onbegin="alert(1)"/></svg>',
        '<svg><animate onend="alert(1)"/></svg>',
      ];
      for (final attack in attacks) {
        expect(
          () => sanitizeStaticSvg(attack),
          throwsFormatException,
          reason: attack,
        );
      }
    });

    test('active and external links fail closed with control obfuscation', () {
      const attacks = <String>[
        '<svg><a href="javascript:alert(1)">x</a></svg>',
        '<svg><a href="java\tscript:alert(1)">x</a></svg>',
        '<svg><a href=" data:text/html;base64,PHNjcmlwdD4=">x</a></svg>',
        '<svg><image href="data:image/svg+xml;base64,PHN2Zz48c2NyaXB0Lz48L3N2Zz4="/></svg>',
        '<svg><image href="https://evil.test/pixel.png"/></svg>',
        '<svg><image href="//evil.test/pixel.png"/></svg>',
        '<svg><use href="file:///etc/passwd#x"/></svg>',
        '<svg><a href="content://contacts">x</a></svg>',
      ];
      for (final attack in attacks) {
        expect(
          () => sanitizeStaticSvg(attack),
          throwsFormatException,
          reason: attack,
        );
      }
    });

    test('CSS URL loads and external styles fail closed', () {
      const attacks = <String>[
        '<svg><style>@import "https://evil.test/a.css";</style></svg>',
        '<svg><style>rect { fill: url(https://evil.test/a.svg#x); }</style></svg>',
        '<svg><rect style="fill:url(//evil.test/a)"/></svg>',
        '<svg><rect fill="url(https://evil.test/a)"/></svg>',
        '<svg><link rel="stylesheet" href="https://evil.test/a.css"/></svg>',
        '<svg><style>@font-face { src: "https://evil.test/font"; }</style></svg>',
      ];
      for (final attack in attacks) {
        expect(
          () => sanitizeStaticSvg(attack),
          throwsFormatException,
          reason: attack,
        );
      }
    });

    test('CSS animation, transition and keyframes never rasterize', () {
      const attacks = <String>[
        '<svg><style>@keyframes move { from { opacity: 0 } to { opacity: 1 } }</style></svg>',
        '<svg><style>rect { animation: move 1s infinite; }</style></svg>',
        '<svg><rect style="transition: opacity 1s"/></svg>',
        '<svg><rect style="-webkit-animation-name: move"/></svg>',
        '<svg><style>@-webkit-keyframes move { from { opacity: 0 } }</style></svg>',
        '<svg><style>rect { animation-name: move; transition-property: opacity; }</style></svg>',
        '<svg><style>rect { \\61 nimation: move 1s; }</style></svg>',
      ];
      for (final attack in attacks) {
        expect(
          () => sanitizeStaticSvg(attack),
          throwsFormatException,
          reason: attack,
        );
      }
    });

    test('DTD, processing instructions and malformed documents are rejected', () {
      const attacks = <String>[
        '<!DOCTYPE svg [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><svg><text>&xxe;</text></svg>',
        '<?xml-stylesheet href="https://evil.test/a.css"?><svg/>',
        '<svg><rect></svg>',
        '<html><svg/></html>',
        '',
      ];
      for (final attack in attacks) {
        expect(
          () => sanitizeStaticSvg(attack),
          throwsFormatException,
          reason: attack,
        );
      }
    });

    test('an ordinary static SVG remains usable', () {
      final sanitized = sanitizeStaticSvg(
        '<svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" '
        'viewBox="0 0 12 12"><rect width="12" height="12" fill="#fff"/></svg>',
      );
      expect(sanitized, contains('<rect'));
      expect(sanitized, contains('viewBox="0 0 12 12"'));
    });
  });

  group('native rasterization boundary', () {
    late List<MethodCall> calls;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(StaticRichContentRenderer.channel, (
        call,
      ) async {
        calls.add(call);
        return Uint8List.fromList(_tinyPng);
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(
        StaticRichContentRenderer.channel,
        null,
      );
    });

    test('hostile input never reaches the native renderer', () async {
      await expectLater(
        StaticRichContentRenderer.renderSvgPng(
          '<svg><script>fetch("https://evil.test")</script></svg>',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(calls, isEmpty);
    });

    test(
      'sanitized static SVG returns real bytes from the pixel channel',
      () async {
        final bytes = await StaticRichContentRenderer.renderSvgPng(
          '<svg viewBox="0 0 1 1"><rect width="1" height="1"/></svg>',
        );
        expect(bytes, _tinyPng);
        expect(calls.single.method, 'renderSvgPng');
        expect(calls.single.arguments, isA<Map>());
        final args = calls.single.arguments as Map;
        expect(args['svg'], isNot(contains('<script')));
        expect(args.containsKey('cookie'), isFalse);
        expect(args.containsKey('authorization'), isFalse);
      },
    );

    test(
      'Mermaid crosses only as source and returns offline PNG pixels',
      () async {
        final bytes = await StaticRichContentRenderer.renderMermaidPng(
          'flowchart LR\nA --> B',
        );
        expect(bytes, _tinyPng);
        expect(calls.single.method, 'renderMermaidPng');
        final args = calls.single.arguments as Map;
        expect(args['source'], 'flowchart LR\nA --> B');
        expect(
          args['requestId'],
          isA<String>().having((id) => id.isNotEmpty, 'nonempty', isTrue),
        );
        expect(args['timeoutMs'], 15000);
        expect(args.containsKey('cookie'), isFalse);
        expect(args.containsKey('authorization'), isFalse);
      },
    );

    test('blank Mermaid never starts a renderer', () async {
      await expectLater(
        StaticRichContentRenderer.renderMermaidPng(' \n '),
        throwsA(isA<FormatException>()),
      );
      expect(calls, isEmpty);
    });
  });
}
