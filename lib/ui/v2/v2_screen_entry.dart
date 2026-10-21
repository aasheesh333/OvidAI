import 'package:flutter/widgets.dart';

/// One entry in the UI v2 gallery. The builder returns a complete screen
/// (including its own `OScaffold`); the gallery only supplies the frame.
class V2ScreenEntry {
  const V2ScreenEntry({
    required this.id,
    required this.title,
    required this.group,
    required this.summary,
    required this.builder,
    this.isSheet = false,
  });

  final String id;
  final String title;
  final String group;
  final String summary;
  final WidgetBuilder builder;

  /// Sheet bodies need a Material host when shown outside `showOSheet`.
  final bool isSheet;
}

