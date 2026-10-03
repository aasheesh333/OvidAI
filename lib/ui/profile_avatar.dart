import 'package:flutter/material.dart';
import '../core/theme.dart';

/// Shared by Settings and Account. The fallback remains visible while loading
/// and after a missing, malformed or failed image; no blank profile circle.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key, this.photoUrl, this.radius = 22});
  final String? photoUrl;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(photoUrl?.trim() ?? '');
    final valid = uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
    final fallback = Icon(Icons.person, size: radius, color: Aether.textMuted);
    return Semantics(
      label: 'Profile image',
      image: true,
      child: ClipOval(
        child: Container(
          width: radius * 2,
          height: radius * 2,
          color: Aether.surfaceRaised,
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
}
