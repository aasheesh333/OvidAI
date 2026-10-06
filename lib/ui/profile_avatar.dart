import 'package:flutter/material.dart';
import '../core/theme.dart';

/// Shared by Settings, Account and the Sidebar header. The fallback remains
/// visible while loading and after a missing, malformed or failed image —
/// no blank profile circle.
///
/// 2026-10-04 polish: adds a hairline ring, soft inner shadow and a
/// deterministic initial glyph fallback (when [displayName] is provided).
/// All behaviour from the previous implementation is preserved so legacy
/// call sites keep rendering the generic person icon as before.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    this.photoUrl,
    this.radius = 22,
    this.displayName,
  });

  final String? photoUrl;
  final double radius;

  /// Optional name — the first alphabetic character is used as the fallback
  /// glyph. If null (default), the fallback is the generic person icon so
  /// nothing visible changes for existing call sites.
  final String? displayName;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(photoUrl?.trim() ?? '');
    final valid = uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
    final fallback = _buildFallback();
    return Semantics(
      label: 'Profile image',
      image: true,
      excludeSemantics: true,
      child: Container(
        width: radius * 2,
        height: radius * 2,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Aether.surfaceRaised,
          border: Border.all(color: Aether.hairlineStrong, width: 1),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              offset: Offset(0, 1),
              blurRadius: 2,
            ),
          ],
        ),
        child: ClipOval(
          child: valid
              ? Image.network(
                  uri.toString(),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => fallback,
                  loadingBuilder: (_, child, progress) =>
                      progress == null ? child : fallback,
                )
              : fallback,
        ),
      ),
    );
  }

  Widget _buildFallback() {
    final name = displayName?.trim() ?? '';
    if (name.isEmpty) {
      return Icon(Icons.person, size: radius, color: Aether.textMuted);
    }
    final glyph = _initialOf(name);
    return Center(
      child: Text(
        glyph,
        style: TextStyle(
          fontSize: radius * 0.9,
          fontWeight: FontWeight.w700,
          color: Aether.textMuted,
          height: 1.0,
        ),
      ),
    );
  }

  String _initialOf(String name) {
    for (final rune in name.runes) {
      final ch = String.fromCharCode(rune);
      final up = ch.toUpperCase();
      if (up != up.toLowerCase()) return up;
    }
    // Fallback for all-non-alphabetic names (emoji, digits): the first rune.
    final first = name.characters.isEmpty ? '?' : name.characters.first;
    return first.toUpperCase();
  }
}
