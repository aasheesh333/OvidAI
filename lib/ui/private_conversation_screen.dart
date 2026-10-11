import 'package:flutter/material.dart';
import '../core/private_sync/dto.dart';
import '../core/private_sync/production.dart';
import 'widgets/memo_listenable_builder.dart';

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
  Widget build(BuildContext context) => MemoListenableBuilder(
    // Rebuild on archive changes only, not on every delivery-status notify.
    listenable: owner,
    memoKey: () => owner.recordsKey,
    builder: (context) {
      final archive = owner.archive;
      final conversations = archive.conversationTitles.entries.toList();
      final rows = conversationId == null
          ? const <SyncReplayRecord>[]
          : archive.transcripts[conversationId] ?? const <SyncReplayRecord>[];
      final empty = conversationId == null
          ? !archive.hasTranscripts
          : rows.isEmpty;
      final header = <Widget>[
        const Text(
          'Restored text is read-only. Nothing here can start an agent or execute a tool.',
        ),
        const SizedBox(height: 16),
        if (!owner.available)
          const Text('Sign in to the account that owns this archive.')
        else if (empty)
          const Text('No restored conversations yet.'),
      ];
      final itemCount = !owner.available || empty
          ? 0
          : conversationId == null
          ? conversations.length
          : rows.length;
      return Scaffold(
        appBar: AppBar(
          title: Text(
            conversationId == null
                ? 'Restored conversations'
                : 'Read-only transcript',
          ),
        ),
        // Lazy: only visible conversations / transcript rows are built.
        body: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: header.length + itemCount,
          itemBuilder: (context, i) {
            if (i < header.length) return header[i];
            final index = i - header.length;
            if (conversationId == null) {
              final entry = conversations[index];
              return ListTile(
                key: ValueKey('private-conversation-${entry.key}'),
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
              );
            }
            final row = rows[index];
            final payload = row.payload as TranscriptPayload;
            return Card(
              key: ValueKey('private-transcript-${row.recordId}'),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${payload.kind.name} · ${row.record.createdAt}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 8),
                    SelectableText(payload.text),
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
