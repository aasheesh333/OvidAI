import 'dart:math';
import 'package:flutter/material.dart';
import '../core/account_service.dart';
import '../core/legal_links.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';
import 'widgets/external_link.dart';

class AccountDeletionPanel extends StatefulWidget {
  const AccountDeletionPanel({
    super.key,
    required this.service,
    this.usesPassword = false,
    required this.reauthenticate,
    required this.requestDeletion,
    this.restore,
    this.canReauthenticate = true,
    this.uid,
  });
  final AccountService service;
  // Kept as an ignored source-compatibility parameter for existing consumers.
  // Password entry is never rendered or passed to reauthentication.
  final bool usesPassword;
  final Future<String?> Function(String? unused) reauthenticate;
  final Future<AccountDeletion> Function(String requestId) requestDeletion;

  /// Account-owner restore (`FirebaseService.restoreAccount`), so the
  /// app-wide deletion receipt is cleared together with the server request.
  /// Returns the latest receipt. Falls back to [AccountService.cancelDeletion]
  /// only when no owner is supplied.
  final Future<AccountDeletion?> Function()? restore;

  /// False when no linked sign-in method can verify the account in this
  /// build (legacy password only, or a provider disabled here). In-app
  /// deletion is then impossible, so the web/email request is offered.
  final bool canReauthenticate;

  /// Prefilled into the email deletion request.
  final String? uid;

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
      builder: (dialog) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          // Only the body scrolls; header and footer actions stay pinned so
          // "Request deletion" / "Keep account" remain reachable on short
          // viewports (AetherCard's Column is mainAxisSize.min, so the
          // Flexible body shrinks to fit the Dialog's bounded height).
          child: AetherCard(
            title: Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 20,
                  color: Aether.warn,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Delete your account?', style: AetherType.title),
                ),
              ],
            ),
            footer: OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: 10,
              overflowSpacing: 8,
              children: [
                AetherGhostButton(
                  label: 'Keep account',
                  onPressed: () => Navigator.pop(dialog, false),
                ),
                AetherDangerButton(
                  label: 'Request deletion',
                  onPressed: () => Navigator.pop(dialog, true),
                ),
              ],
            ),
            child: Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'The server will retain your request for 24 hours. Signing in does not cancel deletion; choose Restore account explicitly before the deadline. After the deadline, your Ovid identity, profile, cloud data and cloud keys will be removed.\n\nLocal workspaces and data held by third-party providers are not erased by this action.',
                      style: AetherType.body,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Next, verify with a social provider or phone linked to this account.',
                      style: AetherType.bodyMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
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

  Future<void> _restore() async {
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
      final restore = widget.restore;
      final status = restore != null
          ? await restore()
          : await widget.service.cancelDeletion();
      if (mounted && status != null) setState(() => _status = status);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _countdown() {
    final deleteAfter = _status?.deleteAfter;
    if (_status?.isPending != true || deleteAfter == null) return null;
    final remaining = deleteAfter.difference(DateTime.now());
    if (remaining.isNegative) return 'Pending finalization';
    final h = remaining.inHours;
    final m = remaining.inMinutes.remainder(60);
    return '${h}h ${m.toString().padLeft(2, '0')}m remaining';
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.service.enabled;
    // Play requires a working deletion path in every build: when the in-app
    // flow cannot run, offer the web form and a prefilled email instead.
    final offerRequest = !enabled || !widget.canReauthenticate;
    final pending = _status?.isPending == true;
    final cancelled = _status?.state == 'cancelled';
    final countdown = _countdown();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pending) ...[
          Container(
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: Aether.warn,
                  width: 3,
                  style: BorderStyle.solid,
                ),
              ),
            ),
            child: AetherCard(
              color: Aether.warn.withValues(alpha: 0.06),
              title: Row(
                children: [
                  Icon(
                    Icons.hourglass_bottom,
                    size: 18,
                    color: Aether.warn,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('Deletion requested', style: AetherType.title),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (countdown != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        countdown,
                        style: AetherType.h2.copyWith(
                          fontFamily: Aether.mono,
                          color: Aether.warn,
                        ),
                      ),
                    ),
                  Text(
                    'Deletion requested. Scheduled after ${_status!.deleteAfter!.toUtc().toIso8601String()} (UTC). Restore the account explicitly before then if you want to keep it.',
                    style: AetherType.body,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (cancelled) ...[
          AetherCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.check_circle_outline,
                  size: 18,
                  color: Aether.success,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Your deletion request was cancelled.',
                    style: AetherType.body,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (_error != null) ...[
          AetherCard(
            color: Aether.danger.withValues(alpha: 0.06),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, size: 18, color: Aether.danger),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _error!,
                    style: AetherType.body.copyWith(color: Aether.danger),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: ClipRRect(
              borderRadius: BorderRadius.all(
                Radius.circular(AetherRadius.rPill),
              ),
              child: LinearProgressIndicator(minHeight: 3),
            ),
          ),
        if (pending)
          AetherGhostButton(
            label: 'Restore account',
            icon: Icons.restore,
            onPressed: _busy ? null : _restore,
          )
        else if (offerRequest)
          _DeletionRequestFallback(
            reason: enabled
                ? 'None of the sign-in methods linked to this account can '
                      'verify a deletion in this version of the app.'
                : 'In-app account deletion is not available in this version '
                      'of the app yet.',
            uid: widget.uid,
          )
        else
          AetherDangerButton(
            label: 'Delete your account',
            icon: Icons.delete_forever_outlined,
            onPressed: _busy ? null : _delete,
          ),
        if (enabled) ...[
          const SizedBox(height: 6),
          AetherGhostButton(
            label: 'Refresh deletion status',
            icon: Icons.refresh,
            onPressed: _busy ? null : _refresh,
          ),
        ],
      ],
    );
  }
}

/// Deletion request outside the in-app flow: the public web form (also the
/// Play Console "Delete account URL") and a prefilled support email.
class _DeletionRequestFallback extends StatelessWidget {
  const _DeletionRequestFallback({required this.reason, this.uid});
  final String reason;
  final String? uid;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AetherCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 18, color: Aether.textMuted),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '$reason You can still request deletion on the web or by '
                  'email. We remove your Ovid identity, profile, cloud data '
                  'and cloud keys, and confirm by email.',
                  style: AetherType.body,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        AetherDangerButton(
          label: 'Request deletion',
          icon: Icons.open_in_new,
          onPressed: () =>
              openExternalLink(context, LegalLinks.accountDeletionRequest),
        ),
        const SizedBox(height: 6),
        AetherGhostButton(
          label: 'Email a deletion request',
          icon: Icons.mail_outline,
          onPressed: () => openExternalLink(
            context,
            LegalLinks.accountDeletionMail(uid: uid).toString(),
          ),
        ),
      ],
    );
  }
}
