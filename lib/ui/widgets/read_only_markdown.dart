import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../core/theme.dart';

/// Selectable Markdown for text that came from someone else (shared links,
/// live sessions). Links are shown but never auto-opened; images are not
/// fetched, so a shared message cannot make this device load remote content.
class ReadOnlyMarkdown extends StatelessWidget {
  const ReadOnlyMarkdown(this.data, {super.key, this.fontSize = 14, this.color});

  final String data;
  final double fontSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final body = color ?? Aether.text;
    final text = TextStyle(
      fontSize: fontSize,
      height: (fontSize + 10) / fontSize,
      color: body,
    );
    return MarkdownBody(
      data: data,
      selectable: true,
      imageBuilder: (uri, title, alt) => Text(
        alt?.isNotEmpty == true ? '[image: $alt]' : '[image]',
        style: text.copyWith(color: Aether.textMuted),
      ),
      styleSheet: MarkdownStyleSheet(
        p: text,
        h1: text.copyWith(fontSize: fontSize + 6, fontWeight: FontWeight.w700),
        h2: text.copyWith(fontSize: fontSize + 4, fontWeight: FontWeight.w700),
        h3: text.copyWith(fontSize: fontSize + 2, fontWeight: FontWeight.w700),
        strong: TextStyle(fontWeight: FontWeight.w600, color: body),
        em: TextStyle(fontStyle: FontStyle.italic, color: body),
        a: TextStyle(color: Aether.accent, decoration: TextDecoration.underline),
        listBullet: text,
        code: TextStyle(
          fontFamily: Aether.mono,
          fontSize: fontSize - 1.5,
          color: Aether.accent,
          backgroundColor: Colors.transparent,
        ),
        codeblockDecoration: BoxDecoration(
          color: Aether.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Aether.hairline),
        ),
        codeblockPadding: const EdgeInsets.all(12),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: Aether.hairlineStrong, width: 3)),
        ),
        blockquotePadding: const EdgeInsets.only(left: 10),
        tableBorder: TableBorder.all(color: Aether.hairline),
      ),
    );
  }
}
