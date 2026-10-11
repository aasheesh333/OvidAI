import 'package:flutter/foundation.dart';

import 'dto.dart';

/// Read-only views over the restored private archive, built once per store
/// change (see `PrivateSyncProduction.archive`) instead of on every sync
/// status notification.
class PrivateArchiveIndex {
  PrivateArchiveIndex._({
    required this.hasTranscripts,
    required this.conversationTitles,
    required this.transcripts,
    required this.activity,
  });

  static final empty = PrivateArchiveIndex._(
    hasTranscripts: false,
    conversationTitles: const {},
    transcripts: const {},
    activity: const [],
  );

  /// Number of index builds (test hook).
  @visibleForTesting
  static int debugBuilds = 0;

  factory PrivateArchiveIndex.build(Iterable<SyncReplayRecord> records) {
    debugBuilds++;
    final transcriptRows = <SyncReplayRecord>[];
    final activity = <SyncReplayRecord>[];
    for (final row in records) {
      switch (row.payload) {
        case TranscriptPayload():
          transcriptRows.add(row);
        case ActivityPayload() || UsagePayload():
          activity.add(row);
        default:
          break;
      }
    }
    transcriptRows.sort(
      (a, b) => a.record.createdAt.compareTo(b.record.createdAt),
    );
    activity.sort((a, b) => b.record.createdAt.compareTo(a.record.createdAt));
    final titles = <String, String>{};
    final byConversation = <String, List<SyncReplayRecord>>{};
    for (final row in transcriptRows) {
      final id = row.record.conversationId;
      if (id == null) continue;
      titles[id] =
          (row.payload as TranscriptPayload).displayTitle ?? 'Conversation';
      byConversation.putIfAbsent(id, () => []).add(row);
    }
    return PrivateArchiveIndex._(
      hasTranscripts: transcriptRows.isNotEmpty,
      conversationTitles: Map.unmodifiable(titles),
      transcripts: {
        for (final e in byConversation.entries)
          e.key: List<SyncReplayRecord>.unmodifiable(e.value),
      },
      activity: List.unmodifiable(activity),
    );
  }

  /// Any transcript row exists (including rows without a conversation id).
  final bool hasTranscripts;

  /// conversationId → latest display title, in order of first message.
  final Map<String, String> conversationTitles;

  /// conversationId → transcript rows, oldest first.
  final Map<String, List<SyncReplayRecord>> transcripts;

  /// Activity and usage rows, newest first.
  final List<SyncReplayRecord> activity;
}
