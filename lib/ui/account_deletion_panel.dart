import 'dart:math';
import 'package:flutter/material.dart';
import '../core/account_service.dart';

class AccountDeletionPanel extends StatefulWidget {
  const AccountDeletionPanel({
    super.key,
    required this.service,
    this.usesPassword = false,
    required this.reauthenticate,
    required this.requestDeletion,
  });
  final AccountService service;
  // Kept as an ignored source-compatibility parameter for existing consumers.
  // Password entry is never rendered or passed to reauthentication.
  final bool usesPassword;
  final Future<String?> Function(String? unused) reauthenticate;
  final Future<AccountDeletion> Function(String requestId) requestDeletion;

  @override
  State<AccountDeletionPanel> createState() => _AccountDeletionPanelState();
}

class _AccountDeletionPanelState extends State<AccountDeletionPanel> {
  AccountDeletion? _status;
  String? _error;
  bool _busy = false;
  // Stable across network retries. Server also deduplicates pending requests
  // across app restarts, even when a new request ID is generated.
  final _requestId = List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  @override
  void initState() {
    super.initState();
    if (widget.service.enabled) _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      final status = await widget.service.status();
      if (mounted) {
        setState(() {
          _status = status;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Delete your account?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'The server will retain your request for 24 hours. Signing in again during that time cancels deletion. After the deadline, your Ovid identity, profile, cloud data and cloud keys will be removed.\n\nLocal workspaces and data held by third-party providers are not erased by this action.',
              ),
              const Text(
                'Next, verify with a social provider or phone linked to this account.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Keep account'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Request deletion'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final error = await widget.reauthenticate(null);
      if (error != null) {
        if (error != 'cancelled') throw AccountException(error);
        return;
      }
      if (!mounted) return;
      final status = await widget.requestDeletion(_requestId);
      if (!mounted) return;
      setState(() => _status = status);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.service.enabled)
          const Text(
            'Account deletion is not yet activated on the server. No request has been submitted.',
          ),
        if (_status?.isPending == true)
          Text(
            'Deletion requested. Scheduled after ${_status!.deleteAfter!.toUtc().toIso8601String()} (UTC). Sign in again before then to cancel.',
          ),
        if (_status?.state == 'cancelled')
          const Text('Your deletion request was cancelled.'),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_busy) const LinearProgressIndicator(),
        OutlinedButton.icon(
          onPressed:
              widget.service.enabled && !_busy && _status?.isPending != true
              ? _delete
              : null,
          icon: const Icon(Icons.delete_forever_outlined),
          label: const Text('Delete your account'),
        ),
        if (widget.service.enabled)
          TextButton(
            onPressed: _busy ? null : _refresh,
            child: const Text('Refresh deletion status'),
          ),
      ],
    );
  }
}
