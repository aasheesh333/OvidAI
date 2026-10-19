import 'dart:math';

import 'package:flutter/material.dart';

import '../core/model_limits.dart';
import '../core/settings_actions.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../l10n/l10n.dart';
import 'widgets/aether_primitives.dart';

/// Ovid Cloud's compaction threshold: 80% of the model window, at most 100K
/// tokens (agent-core compaction policy).
int cloudCompactionThreshold(int windowTokens) =>
    min((windowTokens * 0.8).round(), 100000);

String _kTokens(int tokens) {
  if (tokens >= 1000000 && tokens % 1000000 == 0) return '${tokens ~/ 1000000}M';
  if (tokens % 1024 == 0 && tokens < 100000) return '${tokens ~/ 1024}K';
  return '${(tokens / 1000).round()}K';
}

/// SE-011 / SE-012 — "Responses": what these settings really do on Ovid
/// Cloud. Answer length is sent with every message (the cloud caps it at
/// 8K tokens); the "Still working" hint only changes when the app shows that
/// label (runs are never cancelled by it); the context window is shown for
/// information — Ovid Cloud manages compaction itself.
class ResponsesScreen extends StatelessWidget {
  const ResponsesScreen({super.key});

  Future<void> _save(
    BuildContext context,
    String key,
    Object value,
    Future<void> Function() write,
  ) async {
    try {
      await SettingsActions.persist(key, value, write);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.settingsSaveFailed)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(leading: const BackButton(), title: Text(l.responsesTitle)),
      body: AnimatedBuilder(
        animation: AppState.I,
        builder: (context, _) {
          final app = AppState.I;
          final s = app.activeSession;
          final window = ModelLimits.contextWindowFor(
            s?.model ?? '',
            s?.providerId,
          );
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              AetherSectionTitle(
                eyebrow: l.responsesLengthTitle,
                subtitle: l.responsesLengthHelp,
              ),
              RadioGroup<int>(
                groupValue: app.maxOutputTokens,
                onChanged: (v) => _save(
                  context,
                  'ovid_max_output_tokens',
                  v ?? 0,
                  () => app.setMaxOutputTokens(v ?? 0),
                ),
                child: Column(
                  children: [
                    for (final v in AppState.outputTokenPresets)
                      RadioListTile<int>(
                        key: ValueKey('output-$v'),
                        dense: true,
                        activeColor: Aether.accent,
                        title: Text(
                          v == 0 ? l.responsesLengthAuto : _kTokens(v),
                        ),
                        value: v,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              AetherSectionTitle(
                eyebrow: l.responsesHintTitle,
                subtitle: l.responsesHintHelp,
              ),
              RadioGroup<int>(
                groupValue: app.responseTimeoutSec,
                onChanged: (v) {
                  if (v == null) return;
                  _save(
                    context,
                    'ovid_response_timeout_sec',
                    v,
                    () => app.setResponseTimeout(v),
                  );
                },
                child: Column(
                  children: [
                    for (final sec in AppState.timeoutPresets)
                      RadioListTile<int>(
                        key: ValueKey('hint-$sec'),
                        dense: true,
                        activeColor: Aether.accent,
                        title: Text(
                          sec < 60
                              ? l.durationSeconds(sec)
                              : l.durationMinutes(sec ~/ 60),
                        ),
                        subtitle: sec == 300
                            ? Text(l.responsesHintDefault)
                            : null,
                        value: sec,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              AetherSectionTitle(
                eyebrow: l.responsesContextTitle,
                subtitle: l.responsesContextHelp,
              ),
              const SizedBox(height: 8),
              AetherCard(
                key: const ValueKey('context-info'),
                padding: const EdgeInsets.all(14),
                child: Text(
                  l.responsesContextInfo(
                    s?.model.isNotEmpty == true ? s!.model : 'auto',
                    _kTokens(window),
                    _kTokens(cloudCompactionThreshold(window)),
                  ),
                  style: AetherType.bodyMuted,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
