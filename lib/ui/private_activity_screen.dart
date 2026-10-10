import 'package:flutter/material.dart';
import '../core/private_sync/dto.dart';
import '../core/private_sync/production.dart';

class PrivateActivityScreen extends StatelessWidget {
  const PrivateActivityScreen({super.key, required this.owner});
  final PrivateSyncProduction owner;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: owner,
    builder: (context, _) {
      final rows =
          owner.records
              .where(
                (r) =>
                    r.payload is ActivityPayload || r.payload is UsagePayload,
              )
              .toList()
            ..sort((a, b) => b.record.createdAt.compareTo(a.record.createdAt));
      return Scaffold(
        appBar: AppBar(title: const Text('Private activity')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Read-only activity from your private archive. These records never resume work.',
            ),
            if (!owner.available)
              const Text('Sign in to view this account’s activity.')
            else if (rows.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('No restored activity yet.'),
              ),
            for (final row in rows)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(row.record.createdAt),
                      if (row.payload case final ActivityPayload activity) ...[
                        Text(activity.title),
                        Text(activity.status.name),
                        SelectableText(activity.detail),
                      ],
                      if (row.payload case final UsagePayload usage) ...[
                        Text('${usage.requestedModel} · ${usage.outcome.name}'),
                        Text(
                          'Input: ${usage.inputTokens ?? 'unknown'} · Output: ${usage.outputTokens ?? 'unknown'}',
                        ),
                        Text('Source: ${usage.usageProvenance.name}'),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
