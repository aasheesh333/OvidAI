import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../core/theme.dart';
import '../core/state.dart';

/// Providers screen — BYOK list with search. Opened from Settings.
class ProvidersScreen extends StatefulWidget {
  const ProvidersScreen({super.key});
  @override
  State<ProvidersScreen> createState() => _ProvidersScreenState();
}

class _ProvidersScreenState extends State<ProvidersScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;

    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Providers'),
      ),
      body: AnimatedBuilder(
        animation: app,
        builder: (_, __) {
          // NOTE: filtered list ANDAR compute hoti hai — AppState change pe
          // (add provider, fetch models, remove model) turant re-list hota hai.
          final filtered = app.providers
              .where((p) =>
                  p.name.toLowerCase().contains(_query.toLowerCase()) ||
                  p.baseUrl.toLowerCase().contains(_query.toLowerCase()))
              .toList();
          return ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: 'Search providers…',
                    prefixIcon: Icon(Icons.search,
                        size: 16, color: Aether.textFaint),
                    isDense: true,
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 10),
                child: Text(
                  'Keys never leave this device. Free providers work with zero setup.',
                  style:
                      TextStyle(fontSize: 12.5, color: Aether.textMuted),
                ),
              ),
              for (final p in filtered) ProviderCard(provider: p),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Aether.accent,
                    side: BorderSide(
                        color: Aether.accent.withValues(alpha: 0.4)),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add custom provider',
                      style: TextStyle(fontSize: 13)),
                  onPressed: () => addProviderSheet(context),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

void addProviderSheet(BuildContext context) {
  final name = TextEditingController();
  final url = TextEditingController();
  final key = TextEditingController();
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Add custom provider',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text('Any OpenAI-compatible endpoint works.',
              style:
                  TextStyle(fontSize: 12.5, color: Aether.textMuted)),
          const SizedBox(height: 16),
          TextField(
              controller: name,
              style: const TextStyle(fontSize: 14),
              decoration: const InputDecoration(
                  hintText: 'Name (e.g. Together AI)')),
          const SizedBox(height: 10),
          TextField(
              controller: url,
              style: const TextStyle(fontSize: 14),
              decoration: const InputDecoration(
                  hintText: 'Base URL (https://…/v1)')),
          const SizedBox(height: 10),
          TextField(
              controller: key,
              obscureText: true,
              style: const TextStyle(fontSize: 14),
              decoration:
                  const InputDecoration(hintText: 'API key (optional)')),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Aether.accent,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
              onPressed: () {
                if (name.text.trim().isEmpty) return;
                AppState.I.providers.add(ProviderConfig(
                  name: name.text.trim(),
                  description: 'Custom provider',
                  baseUrl: url.text.trim(),
                  apiKey: key.text.trim(),
                  custom: true,
                ));
                AppState.I.refresh();
                Navigator.pop(ctx);
              },
              child: const Text('Add provider',
                  style: TextStyle(fontSize: 13.5)),
            ),
          ),
        ],
      ),
    ),
  );
}

class ProviderCard extends StatelessWidget {
  final ProviderConfig provider;
  const ProviderCard({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      decoration: BoxDecoration(
        color: Aether.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Aether.hairline),
      ),
      child: Theme(
        data: Theme.of(context)
            .copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          childrenPadding:
              const EdgeInsets.fromLTRB(14, 0, 14, 14),
          leading: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Aether.surfaceRaised,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Text(
                provider.name.substring(0, 1).toUpperCase(),
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Aether.textMuted),
              ),
            ),
          ),
          title: Row(children: [
            Flexible(
                child: Text(provider.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600))),
            const SizedBox(width: 8),
            if (provider.isFree)
              const Tag('FREE',
                  color: Aether.success, filled: true)
            else if (provider.hasKey)
              const Tag('CONNECTED',
                  color: Aether.accent, filled: true)
            else
              const Tag('BYOK'),
          ]),
          subtitle: Text(provider.baseUrl,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 11, color: Aether.textFaint)),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(provider.description,
                  style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.45,
                      color: Aether.textMuted)),
            ),
            const SizedBox(height: 12),
            if (!provider.isFree) ...[
              TextField(
                obscureText: true,
                style: const TextStyle(fontSize: 13.5),
                controller:
                    TextEditingController(text: provider.apiKey),
                onChanged: (v) => provider.apiKey = v,
                decoration: InputDecoration(
                  hintText: 'API key — stored only on this device',
                  suffixIcon: provider.hasKey
                      ? const Icon(Icons.check_circle,
                          size: 17, color: Aether.success)
                      : null,
                ),
              ),
              const SizedBox(height: 10),
            ],
            TextField(
              style: const TextStyle(
                  fontSize: 13.5, fontFamily: Aether.mono),
              controller: TextEditingController(text: provider.baseUrl),
              onChanged: (v) => provider.baseUrl = v,
              decoration:
                  const InputDecoration(hintText: 'Base URL'),
            ),
            const SizedBox(height: 10),
            Row(children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Aether.textMuted,
                  side: const BorderSide(color: Aether.hairlineStrong),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  minimumSize: Size.zero,
                ),
                icon: const Icon(Icons.sync, size: 14),
                label: provider.models.isEmpty
                    ? const Text('Fetch models', style: TextStyle(fontSize: 12))
                    : Text('Re-fetch (${provider.models.length})',
                        style: const TextStyle(fontSize: 12)),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  messenger.showSnackBar(SnackBar(
                      content: Text(
                          'Fetching models from ${provider.name}…')));
                  try {
                    var url = provider.baseUrl;
                    if (!url.endsWith('/')) url += '/';
                    // NVIDIA NIM and OpenAI-compatible /models endpoint
                    final uri = Uri.parse('${url}models');
                    final res = await http.get(uri, headers: {
                      if (provider.apiKey.isNotEmpty)
                        'Authorization': 'Bearer ${provider.apiKey}',
                    }).timeout(const Duration(seconds: 15));
                    if (res.statusCode == 200) {
                      final j = jsonDecode(res.body);
                      final List fetched = j['data'] ?? j['models'] ?? [];
                      final ids = [
                        for (final m in fetched)
                          (m is Map ? (m['id'] ?? m['name'] ?? '') : '$m')
                              .toString()
                      ].where((s) => s.isNotEmpty).toList();
                      if (ids.isEmpty) {
                        provider.models.clear();
                      } else {
                        // merge: keep user's manual additions, update list
                        final existing = provider.models.toSet();
                        for (final id in ids) {
                          if (!existing.contains(id)) {
                            provider.models.add(id);
                            existing.add(id);
                          }
                        }
                      }
                      AppState.I.refresh();
                      messenger.showSnackBar(SnackBar(
                          content: Text(
                              '${ids.length} models fetched ✓')));
                    } else {
                      messenger.showSnackBar(SnackBar(
                          content: Text(
                              'Failed: HTTP ${res.statusCode} — check key/URL')));
                    }
                  } catch (e) {
                    messenger.showSnackBar(SnackBar(
                        content: Text('Fetch failed: $e')));
                  }
                },
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Aether.textMuted,
                  side: const BorderSide(color: Aether.hairlineStrong),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  minimumSize: Size.zero,
                ),
                icon: const Icon(Icons.add, size: 14),
                label: const Text('Add model ID',
                    style: TextStyle(fontSize: 12)),
                onPressed: () {
                  final c = TextEditingController();
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Add model manually',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600)),
                      content: TextField(
                          controller: c,
                          autofocus: true,
                          style: const TextStyle(
                              fontSize: 13.5,
                              fontFamily: Aether.mono),
                          decoration: const InputDecoration(
                              hintText: 'e.g. gpt-5.2-codex')),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Cancel')),
                        TextButton(
                          onPressed: () {
                            final id = c.text.trim();
                            if (id.isNotEmpty) {
                              provider.models.add(id);
                              AppState.I.refresh();
                            }
                            Navigator.pop(ctx);
                          },
                          child: const Text('Add',
                              style: TextStyle(color: Aether.accent)),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(width: 10),
              if (provider.models.isNotEmpty)
                Expanded(
                  child: Text(
                      '${provider.models.length} models available',
                      style: const TextStyle(
                          fontSize: 11.5,
                          color: Aether.textFaint)),
                ),
            ]),
            if (provider.models.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final m in provider.models.take(8))
                      _ModelChip(
                        model: m,
                        providerName: provider.name,
                        onRemove: () {
                          AppState.I.removeModel(provider.name, m);
                        },
                      ),
                    if (provider.models.length > 8)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 4.5),
                        decoration: BoxDecoration(
                          color: Aether.surfaceAlt,
                          borderRadius: BorderRadius.circular(7),
                          border:
                              Border.all(color: Aether.hairline),
                        ),
                        child: Text(
                            '+${provider.models.length - 8} more',
                            style: const TextStyle(
                                fontSize: 11,
                                color: Aether.textFaint)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Model chip with a remove (×) icon — lets users delete fetched
/// or manually added model IDs.
class _ModelChip extends StatefulWidget {
  final String model;
  final String providerName;
  final VoidCallback onRemove;
  const _ModelChip({
    required this.model,
    required this.providerName,
    required this.onRemove,
  });

  @override
  State<_ModelChip> createState() => _ModelChipState();
}

class _ModelChipState extends State<_ModelChip> {
  bool _confirming = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 9, top: 4.5, bottom: 4.5),
      decoration: BoxDecoration(
        color: Aether.surfaceAlt,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
            color: _confirming
                ? Aether.danger.withValues(alpha: 0.5)
                : Aether.hairline),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(widget.model,
            style: TextStyle(
                fontSize: 11,
                fontFamily: Aether.mono,
                color: _confirming ? Aether.danger : Aether.textMuted)),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: () {
            if (_confirming) {
              widget.onRemove();
            } else {
              setState(() => _confirming = true);
              Future.delayed(const Duration(seconds: 2), () {
                if (mounted) setState(() => _confirming = false);
              });
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            child: Icon(
              _confirming ? Icons.delete_outline : Icons.close,
              size: 12,
              color: _confirming ? Aether.danger : Aether.textFaint,
            ),
          ),
        ),
      ]),
    );
  }
}
}
