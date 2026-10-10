import 'package:flutter/material.dart';
import '../core/private_sync/dto.dart';
import '../core/private_sync/production.dart';

/// Text-only archive: no execution, attachment opening, or live-chat hydration.
class PrivateConversationScreen extends StatelessWidget {
  const PrivateConversationScreen({
    super.key,
    required this.owner,
    this.conversationId,
  });
  final PrivateSyncProduction owner;
  final String? conversationId;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: owner,
    builder: (context, _) {
      final rows =
          owner.records
              .where(
                (r) =>
                    r.payload is TranscriptPayload &&
                    (conversationId == null ||
                        r.record.conversationId == conversationId),
              )
              .toList()
            ..sort((a, b) => a.record.createdAt.compareTo(b.record.createdAt));
      final conversations = <String, String>{};
      for (final row in rows) {
        final id = row.record.conversationId;
        if (id != null) {
          conversations[id] =
              (row.payload as TranscriptPayload).displayTitle ?? 'Conversation';
        }
      }
      return Scaffold(
        appBar: AppBar(
          title: Text(
            conversationId == null
                ? 'Restored conversations'
                : 'Read-only transcript',
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Restored text is read-only. Nothing here can start an agent or execute a tool.',
            ),
            const SizedBox(height: 16),
            if (!owner.available)
              const Text('Sign in to the account that owns this archive.')
            else if (rows.isEmpty)
              const Text('No restored conversations yet.')
            else if (conversationId == null)
              for (final entry in conversations.entries)
                ListTile(
                  title: Text(entry.value),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PrivateConversationScreen(
                        owner: owner,
                        conversationId: entry.key,
                      ),
                    ),
                  ),
                )
            else
              for (final row in rows)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${(row.payload as TranscriptPayload).kind.name} · ${row.record.createdAt}',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        const SizedBox(height: 8),
                        SelectableText((row.payload as TranscriptPayload).text),
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
