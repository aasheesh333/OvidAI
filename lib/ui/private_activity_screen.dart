import 'package:flutter/material.dart';
import '../core/private_sync/dto.dart';
import '../core/private_sync/production.dart';
import 'widgets/memo_listenable_builder.dart';

class PrivateActivityScreen extends StatefulWidget {
  const PrivateActivityScreen({super.key, required this.owner});
  final PrivateSyncProduction owner;

  /// Rows shown up front and added per "Load older"; usage rows accrue on
  /// every request, so the list grows without bound.
  static const pageSize = 200;

  @override
  State<PrivateActivityScreen> createState() => _PrivateActivityScreenState();
}

class _PrivateActivityScreenState extends State<PrivateActivityScreen> {
  int _limit = PrivateActivityScreen.pageSize;

  PrivateSyncProduction get owner => widget.owner;

  @override
  Widget build(BuildContext context) => MemoListenableBuilder(
    // Rebuild on archive changes only, not on every delivery-status notify.
    listenable: owner,
    memoKey: () => owner.recordsKey,
    builder: (context) {
      // Pre-indexed and sorted newest first by the controller.
      final rows = owner.archive.activity;
      final shown = rows.length < _limit ? rows.length : _limit;
      final hasOlder = rows.length > shown;
      final header = <Widget>[
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
      ];
      return Scaffold(
        appBar: AppBar(title: const Text('Private activity')),
        body: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: header.length + shown + (hasOlder ? 1 : 0),
          itemBuilder: (context, i) {
            if (i < header.length) return header[i];
            final index = i - header.length;
            if (index == shown) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: OutlinedButton(
                  key: const ValueKey('private-activity-load-older'),
                  onPressed: () => setState(
                    () => _limit += PrivateActivityScreen.pageSize,
                  ),
                  child: Text('Load older (${rows.length - shown} more)'),
                ),
              );
            }
            final row = rows[index];
            return Card(
              key: ValueKey('private-activity-${row.recordId}'),
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
            );
          },
        ),
      );
    },
  );
}
