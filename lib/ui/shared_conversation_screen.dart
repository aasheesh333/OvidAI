import 'package:flutter/material.dart';

import '../core/conversation_share_service.dart';
import '../core/firebase_service.dart';
import '../core/theme.dart';
import '../core/state.dart';
import 'auth_screen.dart';
import 'widgets/aether_primitives.dart';
import 'widgets/read_only_markdown.dart';

class SharedConversationScreen extends StatefulWidget {
  const SharedConversationScreen({
    super.key,
    required this.token,
    this.service,
    @visibleForTesting this.loadSnapshot,
  });
  final String token;

  /// Test seam; production builds the default service.
  final ConversationShareService? service;

  /// Overrides only the public snapshot fetch (tests).
  final Future<ConversationSnapshot> Function(String token)? loadSnapshot;

  @override
  State<SharedConversationScreen> createState() => _SharedConversationScreenState();
}

class _SharedConversationScreenState extends State<SharedConversationScreen> {
  // Mutable: a timeout/offline failure must be retryable (F-181).
  late Future<ConversationSnapshot> _snapshot = _load();
  late final String _forkRequestId = ConversationShareService.newRequestId();
  bool _busy = false;
  String? _error;

  ConversationShareService get _service =>
      widget.service ?? ConversationShareService.production();

  Future<ConversationSnapshot> _load() =>
      widget.loadSnapshot?.call(widget.token) ??
      _service.publicSnapshot(widget.token);

  Future<void> _reload() {
    final next = _load();
    setState(() {
      _snapshot = next;
    });
    return next.then((_) {}, onError: (Object _) {});
  }

  Future<void> _continue() async {
    if (_busy) return;
    final uidBeforeAuth = FirebaseService.I.uid;
    if (!FirebaseService.I.isSignedIn) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const AuthScreen()),
      );
      if (!mounted || !FirebaseService.I.isSignedIn) {
        return;
      }
    }
    final uidAtFork = FirebaseService.I.uid;
    if (uidAtFork == null ||
        (uidBeforeAuth != null && uidBeforeAuth != uidAtFork)) {
      return;
    }
    setState(() { _busy = true; _error = null; });
    final accountToken = AppState.I.sessionAccountToken;
    bool accountIsCurrent() =>
        identical(accountToken, AppState.I.sessionAccountToken) &&
        FirebaseService.I.uid == uidAtFork;
    try {
      final snapshot = await _snapshot;
      if (!accountIsCurrent()) {
        throw const ConversationShareException('Account changed. Please reopen the shared link.');
      }
      final id = await _service.fork(
        widget.token,
        requestId: _forkRequestId,
      );
      if (!accountIsCurrent()) {
        throw const ConversationShareException('Account changed. Please reopen the shared link.');
      }
      final imported = AppState.I.importSharedMessages(
        id,
        [
          for (final message in snapshot.importableMessages)
            Message(role: message.role, content: message.content),
        ],
      );
      if (imported == null) {
        throw const ConversationShareException('This shared snapshot has no importable messages.');
      }
      if (mounted) Navigator.of(context).pop(id);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Shared conversation'),
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: _reload,
        ),
      ],
    ),
    body: FutureBuilder<ConversationSnapshot>(
      future: _snapshot,
      builder: (context, state) {
        if (state.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (state.hasError) {
          final error = state.error;
          return AetherEmptyState(
            icon: Icons.link_off,
            title: 'Could not open this link',
            message: error is ConversationShareException
                ? error.message
                : 'This link is unavailable or expired.',
            action: AetherGhostButton(
              label: 'Retry',
              icon: Icons.refresh,
              onPressed: _reload,
            ),
          );
        }
        final snapshot = state.data!;
        final messages = snapshot.messages;
        // Up to 500 × 20k-char messages: build only the visible bubbles.
        return RefreshIndicator(
          onRefresh: _reload,
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            itemCount: messages.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Read only', style: AetherType.label),
                    const SizedBox(height: 4),
                    Text(
                      'Shared by its owner. Pull down to load the latest version.',
                      style: AetherType.bodyMuted,
                    ),
                    const SizedBox(height: 16),
                  ],
                );
              }
              return SharedMessageBubble(message: messages[i - 1]);
            },
          ),
        );
      },
    ),
    // Pinned so the conversion action is always reachable (F-182).
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_error!, style: TextStyle(color: Aether.danger)),
              ),
            AetherPrimaryButton(
              label: _busy ? 'Continuing…' : 'Continue this chat in Ovid',
              icon: Icons.forum_outlined,
              onPressed: _busy ? null : _continue,
            ),
          ],
        ),
      ),
    ),
  );
}

/// One shared message with its role label (F-179) and Markdown (F-180).
class SharedMessageBubble extends StatelessWidget {
  const SharedMessageBubble({super.key, required this.message});
  final SharedMessage message;

  @override
  Widget build(BuildContext context) {
    final user = message.role == 'user';
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: user ? Aether.accent.withValues(alpha: 0.08) : Aether.surface,
            borderRadius: BorderRadius.circular(AetherRadius.rMd),
            border: Border.all(color: Aether.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(user ? 'User' : 'Assistant', style: AetherType.label),
              const SizedBox(height: 4),
              ReadOnlyMarkdown(message.content),
            ],
          ),
        ),
      ),
    );
  }
}
