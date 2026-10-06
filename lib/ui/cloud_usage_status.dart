import 'package:flutter/material.dart';

import '../core/cloud_usage_store.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Shared freshness/error wording for both allowance surfaces.
///
/// Visibility: the status collapses to nothing when the live cache is fresh and
/// has no error, so an up-to-date allowance never shows a secondary status
/// block. When shown, the status is a compact pill + optional progress hint +
/// caption using the Aether primitives.
class CloudUsageStatus extends StatelessWidget {
  const CloudUsageStatus({super.key, required this.store});
  final CloudUsageStore store;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (_, _) {
        if (!store.stale && store.error == null) return const SizedBox.shrink();

        final hasUsage = store.usage != null;
        final hasError = store.error != null;
        final loading = store.loading;

        final Color pillColor;
        final String pillLabel;
        if (hasError) {
          pillColor = Aether.dangerC;
          pillLabel = 'UNAVAILABLE';
        } else if (loading) {
          pillColor = Aether.accentC;
          pillLabel = 'REFRESHING';
        } else {
          pillColor = Aether.warnLight;
          pillLabel = 'STALE';
        }

        final rows = <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AetherPill(label: pillLabel, color: pillColor),
              if (loading) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    valueColor: AlwaysStoppedAnimation<Color>(Aether.textMuted),
                  ),
                ),
              ],
            ],
          ),
        ];
        if (hasUsage) {
          rows
            ..add(const SizedBox(height: 6))
            ..add(
              Text(
                'Last known allowance · may be out of date',
                style: AetherType.caption,
              ),
            );
        }
        if (hasError) {
          rows
            ..add(const SizedBox(height: 4))
            ..add(Text(store.error!, style: AetherType.caption));
          rows.add(
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: TextButton(
                onPressed: loading ? null : store.refresh,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  minimumSize: const Size(44, 44),
                ),
                child: const Text('Retry'),
              ),
            ),
          );
        }
        if (loading) {
          rows
            ..add(const SizedBox(height: 4))
            ..add(Text('Refreshing allowance…', style: AetherType.caption));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        );
      },
    );
  }
}
