import 'package:flutter/material.dart';
import '../core/collaboration/production.dart';
import '../core/collaboration/models.dart';
import '../core/collaboration/reducer.dart';
import '../core/state.dart';

class CollaborationScreen extends StatefulWidget {
  const CollaborationScreen({super.key, this.controller});
  final CollaborationProduction? controller;
  @override
  State<CollaborationScreen> createState() => _CollaborationScreenState();
}

class _CollaborationScreenState extends State<CollaborationScreen> {
  final _token = TextEditingController();
  final _invite = TextEditingController();
  final _message = TextEditingController();
  bool _busy = false;
  String? _error;
  CollaborationProduction? get owner =>
      widget.controller ?? AppState.I.collaboration;
  @override
  void dispose() {
    _token.dispose();
    _invite.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Collaboration request failed. Check account access and connection, then retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = owner;
    return controller == null
        ? _body(context)
        : AnimatedBuilder(
            animation: controller,
            builder: (_, _) => _body(context),
          );
  }

  Widget _body(BuildContext context) {
    final controller = owner;
    final available = controller?.available == true && !_busy;
    final state = controller?.state;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Collaboration'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: available ? controller!.refresh : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Messages you explicitly send are shared with session members over HTTPS. Incoming messages, model status, usage, and presence are read-only. Remote events never execute agents or tools on this device.',
          ),
          const SizedBox(height: 16),
          if (controller?.configured != true)
            const Text(
              'Not configured in this build. A collaboration HTTPS endpoint is required.',
            )
          else if (controller?.available != true)
            const Text('Sign in and wait for your account to be ready.'),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_busy) const LinearProgressIndicator(),
          if (controller?.sessionToken == null) ...[
            FilledButton(
              onPressed: available ? () => _run(controller!.create) : null,
              child: const Text('Create collaboration'),
            ),
            const Divider(height: 32),
            TextField(
              controller: _token,
              decoration: const InputDecoration(labelText: 'Session token'),
              autocorrect: false,
            ),
            TextField(
              controller: _invite,
              decoration: const InputDecoration(labelText: 'Invitation code'),
              autocorrect: false,
            ),
            OutlinedButton(
              onPressed: available
                  ? () => _run(
                      () => controller!.join(
                        _token.text.trim(),
                        _invite.text.trim(),
                      ),
                    )
                  : null,
              child: const Text('Join collaboration'),
            ),
          ] else ...[
            const Text('Session token — share only with intended members'),
            SelectableText(controller!.sessionToken!),
            TextButton(
              onPressed: available ? () => _run(controller.leaveOrClose) : null,
              child: Text(
                controller.isOwner
                    ? 'Close collaboration'
                    : 'Leave collaboration',
              ),
            ),
            TextButton(
              onPressed: available ? () => _run(controller.disconnect) : null,
              child: const Text('Disconnect on this device'),
            ),
            if (controller.stale)
              const Text(
                'Waiting for fresh server state. Displayed events may be out of date.',
              ),
            if (controller.isOwner) ...[
              OutlinedButton(
                onPressed: available ? () => _run(controller.invite) : null,
                child: const Text('Create one-use invitation'),
              ),
              if (controller.invitationCode != null)
                SelectableText('Invitation code: ${controller.invitationCode}'),
            ],
            const SizedBox(height: 16),
            Text('Members', style: Theme.of(context).textTheme.titleMedium),
            for (final member in state?.members.values ?? const <Member>[])
              ListTile(
                title: Text(member.participantId),
                subtitle: Text('${member.role.name} · ${member.status.name}'),
                trailing:
                    controller.isOwner &&
                        member.role != MemberRole.owner &&
                        member.isActive
                    ? TextButton(
                        onPressed: available
                            ? () => _run(
                                () => controller.revokeMember(
                                  member.participantId,
                                ),
                              )
                            : null,
                        child: const Text('Revoke'),
                      )
                    : null,
              ),
            const Divider(),
            Text(
              'Read-only events',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final message
                in state?.messages ?? const <CollaborationMessage>[])
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${message.author} · ${message.createdAt}'),
                      SelectableText(message.text),
                    ],
                  ),
                ),
              ),
            for (final entry
                in state?.modelStates.entries ??
                    const <MapEntry<String, ParticipantModelState>>[])
              ListTile(
                title: Text(entry.key),
                subtitle: Text(entry.value.toWire().toString()),
              ),
            for (final entry
                in state?.presence.entries ??
                    const <MapEntry<String, PresenceState>>[])
              ListTile(
                title: Text(entry.key),
                subtitle: Text(entry.value.name),
              ),
            const SizedBox(height: 20),
            TextField(
              controller: _message,
              minLines: 2,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Your message to members',
                helperText:
                    'Sending shares this text. It does not run a model.',
              ),
            ),
            FilledButton(
              onPressed: available && state?.status == CollaborationStatus.live
                  ? () => _run(() async {
                      await controller.sendMessage(_message.text);
                      if (mounted) _message.clear();
                    })
                  : null,
              child: const Text('Send my message'),
            ),
          ],
        ],
      ),
    );
  }
}
