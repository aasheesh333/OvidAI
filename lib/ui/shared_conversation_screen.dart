import 'package:flutter/material.dart';

import '../core/conversation_share_service.dart';
import '../core/firebase_service.dart';
import '../core/theme.dart';
import '../core/state.dart';
import 'auth_screen.dart';
import 'widgets/aether_primitives.dart';

class SharedConversationScreen extends StatefulWidget {
  const SharedConversationScreen({super.key, required this.token});
  final String token;

  @override
  State<SharedConversationScreen> createState() => _SharedConversationScreenState();
}

class _SharedConversationScreenState extends State<SharedConversationScreen> {
  late final Future<ConversationSnapshot> _snapshot = _load();
  late final String _forkRequestId = ConversationShareService.newRequestId();
  bool _busy = false;
  String? _error;

  Future<ConversationSnapshot> _load() async {
    return ConversationShareService.production().publicSnapshot(widget.token);
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
      final id = await ConversationShareService.production().fork(
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
    appBar: AppBar(title: const Text('Shared conversation')),
    body: FutureBuilder<ConversationSnapshot>(
      future: _snapshot,
      builder: (context, state) {
        if (state.hasError) return const Center(child: Text('This link is unavailable or expired.'));
        if (!state.hasData) return const Center(child: CircularProgressIndicator());
        final snapshot = state.data!;
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('Read-only snapshot', style: AetherType.h2),
            const SizedBox(height: 8),
            for (final message in snapshot.messages) Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: AetherCard(child: Text(message.content)),
            ),
            if (_error != null) Text(_error!, style: TextStyle(color: Aether.dangerC)),
            AetherPrimaryButton(
              label: _busy ? 'Continuing…' : 'Continue in Ovid Si',
              onPressed: _busy ? null : _continue,
            ),
          ],
        );
      },
    ),
  );
}
