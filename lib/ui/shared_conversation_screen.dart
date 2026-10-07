import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/conversation_share_service.dart';
import '../core/firebase_service.dart';
import '../core/share_link_resolver.dart';
import '../core/theme.dart';
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
  bool _busy = false;
  String? _error;

  Future<ConversationSnapshot> _load() async {
    final response = await http.get(Uri.parse(
      'https://ovidsi.com/s/${widget.token}.json',
    ));
    if (response.statusCode != 200) throw const FormatException('unavailable');
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final messages = (data['messages'] as List).map((row) {
      final value = row as Map<String, dynamic>;
      return SharedMessage(value['role'] as String, value['content'] as String);
    }).toList();
    return ConversationSnapshot.fromJson(data['session_id'] as String, messages);
  }

  Future<void> _continue() async {
    if (_busy) return;
    if (!FirebaseService.I.isSignedIn) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AuthScreen()));
      if (!mounted || !FirebaseService.I.isSignedIn) return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      final id = await ConversationShareService.production().fork(
        widget.token,
        requestId: ConversationShareService.newRequestId(),
      );
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
