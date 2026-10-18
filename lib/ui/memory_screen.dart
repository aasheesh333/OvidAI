import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Memory screen.
///
/// Memory is a server-owned Ovid Cloud store (P3 memory endpoints). Until the
/// read/write endpoint ships this surface is an honest empty state; the local
/// `MemoryStore` is retained only for the one-time history import window
/// (Task 20), not as an editable local memory.
class MemoryScreen extends StatelessWidget {
  const MemoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Memory'),
        backgroundColor: Aether.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          const AetherSectionTitle(
            eyebrow: 'Cloud memory',
            subtitle:
                'Ovid Cloud owns long-term memory for your account. '
                'Memory read and edit arrive with the P3 memory endpoints.',
          ),
          const SizedBox(height: 16),
          AetherCard(
            key: ValueKey('memory-cloud-empty'),
            padding: EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.psychology_outlined, size: 20, color: Aether.accent),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Nothing to show yet',
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
                  'Memory is managed server-side. This build keeps no editable '
                  'on-device memory store; existing local memory is read only '
                  'by the one-time history import.',
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
