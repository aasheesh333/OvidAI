import 'package:flutter/material.dart';

/// A zero-visual-impact live region for asynchronous results that would
/// otherwise change silently.
///
/// TalkBack announces a live region whenever its label changes while the node
/// stays mounted. Keeping the node in the tree (instead of inserting and
/// removing one) is what makes a second "Message sent" announce again. The
/// child is a transparent 1 × 1 box so it never affects layout or painting.
///
/// The host clears [message] after a short delay; an empty label is ignored by
/// TalkBack.
class OLiveRegion extends StatelessWidget {
  const OLiveRegion({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: const SizedBox(width: 1, height: 1),
    );
  }
}
