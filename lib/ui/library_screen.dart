import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'memory_screen.dart';
import 'usage_screen.dart';
import 'widgets/aether_primitives.dart';

/// Library — "what I've made / saved", gathered behind one calm surface.
///
/// Three tabs, switched with the [AetherSegmentedControl] pill and held in an
/// [IndexedStack] so each tab keeps its state (including an unsaved memory
/// draft — the memory editor's dirty-guard stays in force while switching):
///
///   * **Memories** embeds the real [MemoryScreen] unchanged, nested app bar
///     and all, so the editor keeps its single source of truth.
///   * **Artifacts** and **Shares** are placeholders: there is no standalone
///     artifact or share-list store on device yet. Where an existing surface
///     covers the content (generated images), the tab links out to it instead
///     of duplicating it.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(title: const Text('Library')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AetherSpacing.space4,
              AetherSpacing.space2,
              AetherSpacing.space4,
              AetherSpacing.space3,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: AetherSegmentedControl<int>(
                options: const [
                  (value: 0, label: 'Memories', icon: Icons.note_alt_outlined),
                  (value: 1, label: 'Artifacts', icon: Icons.auto_awesome_outlined),
                  (value: 2, label: 'Shares', icon: Icons.share_outlined),
                ],
                value: _tab,
                onChanged: (value) => setState(() => _tab = value),
              ),
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              sizing: StackFit.expand,
              children: const [
                MemoryScreen(),
                _ArtifactsTab(),
                _SharesTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Placeholder for created content. Generated images already have a surface —
/// the receipts panel — so the tab links there rather than rebuilding a list.
class _ArtifactsTab extends StatelessWidget {
  const _ArtifactsTab();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Aether.bg,
      child: AetherEmptyState(
        icon: Icons.auto_awesome_outlined,
        title: 'Nothing made yet',
        message: 'Images and HTML artifacts you create will live here.',
        action: AetherSecondaryButton(
          label: 'Open image receipts',
          icon: Icons.photo_library_outlined,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const ImageReceiptsScreen(),
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder for shared content. Shares are published per chat through the
/// conversation share sheet; there is no device-wide share list to reuse yet.
class _SharesTab extends StatelessWidget {
  const _SharesTab();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Aether.bg,
      child: const AetherEmptyState(
        icon: Icons.share_outlined,
        title: 'No shares yet',
        message: 'Share links are created from a chat’s share action.',
      ),
    );
  }
}
