import 'package:flutter/services.dart';

/// Real clipboard writes for the artifacts library.
///
/// The library never reports success it did not get: a failed platform write
/// returns false so the caller can say so instead of showing a fake
/// "copied" confirmation.
Future<bool> v2CopyArtifactText(String text) async {
  final value = text.trim();
  if (value.isEmpty) return false;
  try {
    await Clipboard.setData(ClipboardData(text: value));
    return true;
  } catch (_) {
    return false;
  }
}
