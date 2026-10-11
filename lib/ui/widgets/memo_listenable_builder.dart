import 'package:flutter/widgets.dart';

/// Listens to [listenable] but rebuilds only when [memoKey] changes, so a
/// screen derived from one slice of a broad notifier (streamed tokens, sync
/// delivery status, unrelated settings) ignores notifications that do not
/// touch that slice. [memoKey] must be cheap: it runs on every notification.
class MemoListenableBuilder extends StatefulWidget {
  const MemoListenableBuilder({
    super.key,
    required this.listenable,
    required this.memoKey,
    required this.builder,
  });

  final Listenable listenable;
  final Object? Function() memoKey;
  final WidgetBuilder builder;

  @override
  State<MemoListenableBuilder> createState() => _MemoListenableBuilderState();
}

class _MemoListenableBuilderState extends State<MemoListenableBuilder> {
  Object? _key;

  @override
  void initState() {
    super.initState();
    _key = widget.memoKey();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant MemoListenableBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.listenable, widget.listenable)) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
    _key = widget.memoKey();
  }

  void _changed() {
    final next = widget.memoKey();
    if (next == _key) return;
    _key = next;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
