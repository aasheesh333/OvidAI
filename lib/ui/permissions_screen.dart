import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Settings → Permissions.
///
/// Permissions are enforced server-side in Ovid Cloud (spec §10): the gateway
/// owns the grants table and the approval policy. There is no local grant
/// store any more, so this surface is a read-only explanation until the P3/P9
/// grants read endpoint ships.
class PermissionsScreen extends StatelessWidget {
  const PermissionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        title: const Text('Permissions'),
        backgroundColor: Aether.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          const AetherSectionTitle(
            eyebrow: 'Server-managed',
            subtitle:
                'Permissions are managed server-side by Ovid Cloud. '
                'Approvals and remembered decisions are scoped to your '
                'account and applied before a tool runs.',
          ),
          const SizedBox(height: 16),
          AetherCard(
            key: ValueKey('permissions-server-managed'),
            padding: EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.shield_outlined, size: 20, color: Aether.accent),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'No local permission grants',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Aether.text,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                Text(
                  'This build keeps no on-device grant list. When a run asks '
                  'to reach a path or host outside its workspace, the answer '
                  'is enforced by the cloud executor. A grants read view '
                  'returns here when the server endpoint is available.',
                  style: AetherType.bodyMuted.copyWith(height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
