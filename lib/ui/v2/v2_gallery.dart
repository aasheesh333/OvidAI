import 'package:flutter/material.dart';

import '../design/o_components.dart';
import '../design/o_theme.dart';
import '../design/o_tokens.dart';
import 'v2_registry.dart';

/// A QA/review surface for every UI v2 screen. Enabled with
/// `--dart-define=OVID_UI_V2=true`; never the production home.
class V2GalleryPage extends StatefulWidget {
  const V2GalleryPage({super.key});

  @override
  State<V2GalleryPage> createState() => _V2GalleryPageState();
}

class _V2GalleryPageState extends State<V2GalleryPage> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final filtered = v2Screens.where((s) {
      final q = _query.trim().toLowerCase();
      if (q.isEmpty) return true;
      return s.title.toLowerCase().contains(q) ||
          s.summary.toLowerCase().contains(q) ||
          s.group.toLowerCase().contains(q);
    }).toList();

    // Preserve declaration order instead of sorting groups alphabetically.
    final groups = <String, List<V2ScreenEntry>>{};
    for (final entry in filtered) {
      groups.putIfAbsent(entry.group, () => <V2ScreenEntry>[]).add(entry);
    }

    return OScaffold(
      appBar: const OAppBar(
        title: 'UI v2',
        subtitle: 'Every screen · light and dark',
        showBack: false,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                OSpace.l,
                OSpace.s,
                OSpace.l,
                OSpace.s,
              ),
              child: OSearchField(
                controller: _search,
                hint: 'Find a screen',
                onChanged: (v) => setState(() => _query = v),
                trailing: _query.isEmpty
                    ? null
                    : OIconButton(
                        icon: Icons.close_rounded,
                        semanticLabel: 'Clear search',
                        tooltip: 'Clear search',
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
            Expanded(
              child: v2Screens.isEmpty
                  ? OEmptyState(
                      icon: Icons.grid_view_rounded,
                      title: 'Screens are still landing',
                      message:
                          'The nine screen groups are building in parallel. '
                          'Pull to refresh when they report done.',
                      action: OButton(
                        label: 'Refresh',
                        onPressed: () => setState(() {}),
                      ),
                    )
                  : filtered.isEmpty
                  ? OEmptyState(
                      icon: Icons.search_off_rounded,
                      title: 'No screen matches "$_query"',
                      message: 'Try "settings", "studio", "chat" or "share".',
                      action: OButton(
                        label: 'Clear search',
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(
                        OSpace.l,
                        0,
                        OSpace.l,
                        OSpace.xxl,
                      ),
                      children: [
                        for (final group in groups.entries) ...[
                          OSectionHeader(label: group.key),
                          OCard(
                            padding: EdgeInsets.zero,
                            child: Column(
                              children: [
                                for (var i = 0; i < group.value.length; i++) ...[
                                  OListRow(
                                    title: group.value[i].title,
                                    subtitle: group.value[i].summary,
                                    trailing: Icon(
                                      Icons.chevron_right_rounded,
                                      color: c.textFaint,
                                    ),
                                    onTap: () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => V2PreviewPage(
                                          entry: group.value[i],
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (i != group.value.length - 1)
                                    Divider(
                                      height: 1,
                                      thickness: 1,
                                      color: c.hairline,
                                    ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: OSpace.l),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Hosts one screen and lets the reviewer flip light/dark without changing the
/// OS setting. The screen keeps its own scaffold and app bar.
class V2PreviewPage extends StatefulWidget {
  const V2PreviewPage({super.key, required this.entry});

  final V2ScreenEntry entry;

  @override
  State<V2PreviewPage> createState() => _V2PreviewPageState();
}

class _V2PreviewPageState extends State<V2PreviewPage> {
  bool? _dark;

  @override
  Widget build(BuildContext context) {
    final dark = _dark ?? Theme.of(context).brightness == Brightness.dark;
    final c = OColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.bg,
        foregroundColor: c.text,
        elevation: 0,
        title: Text(widget.entry.title, style: OType.bodyStrong),
        actions: [
          IconButton(
            tooltip: dark ? 'Preview light' : 'Preview dark',
            onPressed: () => setState(() => _dark = !dark),
            icon: Icon(
              dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            ),
          ),
        ],
      ),
      body: Theme(
        data: dark ? OTheme.dark() : OTheme.light(),
        child: Builder(builder: widget.entry.builder),
      ),
    );
  }
}
