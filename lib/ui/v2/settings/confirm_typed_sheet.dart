import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move this sheet's English copy to the ARB files in the next wave.

/// Copy and state for [V2ConfirmTypedSheet].
///
/// The defaults describe account deletion: the 24-hour grace period, the data
/// that goes away and the Google Play warning. Every string is replaceable so
/// the same sheet can confirm another irreversible action. The only required
/// value is [contact], the email or phone the person must type.
@immutable
class V2ConfirmTypedSheetData {
  const V2ConfirmTypedSheetData({
    required this.contact,
    this.title = 'Delete your account?',
    this.irreversibleLabel = 'Cannot be undone',
    this.intro =
        'Your account is kept for a 24-hour grace period before it is deleted.',
    this.removalsTitle = 'This permanently removes:',
    this.removals = const <String>[
      'Every chat and message',
      'Workspace files and generated artifacts',
      'Global, project and per-session memory',
      'Connectors and saved cloud keys',
      'Drafts, scheduled runs and shared links',
    ],
    this.graceNote =
        'Signing in during the 24-hour grace period cancels the deletion and '
        'restores your account.',
    this.playNote =
        'Your Google Play subscription is not cancelled automatically. '
        'Manage it before deleting, or it keeps renewing.',
    this.playActionLabel = 'Manage Play subscription',
    this.prompt = 'Type your email or phone to confirm',
    this.fieldLabel = 'Email or phone',
    this.mismatchMessage =
        'That does not match the email or phone on your account.',
    this.matchedMessage = 'Matches the email or phone on your account.',
    this.lockHint = 'The button below stays locked until it matches.',
    this.disabledHint =
        'Type the email or phone on your account to enable this action.',
    this.confirmLabel = 'Delete after 24 hours',
    this.cancelLabel = 'Keep account',
  });

  /// Registered email or phone. When empty the sheet falls back to typing
  /// `DELETE`, matching the older data-control confirmation.
  final String contact;

  final String title;

  /// Shown as a danger pill under the title. An empty string hides it.
  final String irreversibleLabel;
  final String intro;
  final String removalsTitle;

  /// Concrete things the action removes. Not an abstract "all your data".
  final List<String> removals;

  /// Reassurance that the account can still be restored, with the window.
  final String graceNote;

  /// Play billing warning. An empty string hides the note and its action.
  final String playNote;
  final String playActionLabel;

  final String prompt;
  final String fieldLabel;
  final String mismatchMessage;
  final String matchedMessage;
  final String lockHint;
  final String disabledHint;
  final String confirmLabel;
  final String cancelLabel;

  /// True when the account has an email or phone to type.
  bool get hasContact => contact.trim().isNotEmpty;

  bool get isEmailContact => hasContact && contact.contains('@');

  /// The exact value the user has to reproduce. `DELETE` is a defensive
  /// fallback for accounts without a contact on file.
  String get confirmationTarget => hasContact ? contact.trim() : 'DELETE';

  /// Case-insensitive match; phone formatting characters are ignored so
  /// `+91 98765 43210` accepts `+919876543210`.
  bool matches(String input) =>
      _normalise(input) == _normalise(confirmationTarget);

  String _normalise(String value) {
    final trimmed = value.trim().toLowerCase();
    if (!hasContact || isEmailContact) return trimmed;
    return trimmed.replaceAll(RegExp(r'[\s().-]'), '');
  }
}

/// A destructive bottom sheet that requires the user to type the account email
/// or phone before the action unlocks.
///
/// Presentational: every action and all copy is injected. Host it with
/// [showConfirmTypedSheet], or place it in a sheet yourself and set
/// [showHandle] to false when the host already draws a grabber.
class V2ConfirmTypedSheet extends StatefulWidget {
  const V2ConfirmTypedSheet({
    super.key,
    required this.data,
    this.onConfirm,
    this.onCancel,
    this.onManageSubscription,
    this.showHandle = true,
  });

  final V2ConfirmTypedSheetData data;

  /// Called only when the typed value matches. The host usually pops `true`.
  final VoidCallback? onConfirm;

  /// Called when the user backs out. The host usually pops `false`.
  final VoidCallback? onCancel;

  /// Opens the Play subscription centre. The button is hidden when null.
  final VoidCallback? onManageSubscription;

  final bool showHandle;

  @override
  State<V2ConfirmTypedSheet> createState() => _V2ConfirmTypedSheetState();
}

class _V2ConfirmTypedSheetState extends State<V2ConfirmTypedSheet> {
  final TextEditingController _typed = TextEditingController();

  bool get _matches => widget.data.matches(_typed.text);

  bool get _canConfirm => _matches && widget.onConfirm != null;

  bool get _showMismatch => _typed.text.trim().isNotEmpty && !_matches;

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  void _confirm() {
    if (!_canConfirm) return;
    FocusManager.instance.primaryFocus?.unfocus();
    widget.onConfirm?.call();
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    return Material(
      color: c.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showHandle) ...[
              const SizedBox(height: OSpace.s),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: c.hairlineStrong,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
            Flexible(
              child: SingleChildScrollView(
                key: const ValueKey('confirm-typed-scroll'),
                padding: const EdgeInsets.fromLTRB(
                  OSpace.l,
                  OSpace.m,
                  OSpace.l,
                  OSpace.l,
                ),
                child: OFadeSlide(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(context),
                      if (data.intro.isNotEmpty) ...[
                        const SizedBox(height: OSpace.m),
                        Text(
                          data.intro,
                          style: OType.body.copyWith(color: c.text),
                        ),
                      ],
                      if (data.removals.isNotEmpty) ...[
                        const SizedBox(height: OSpace.l),
                        _removals(context),
                      ],
                      if (data.graceNote.isNotEmpty) ...[
                        const SizedBox(height: OSpace.m),
                        _graceNote(context),
                      ],
                      if (data.playNote.isNotEmpty) ...[
                        const SizedBox(height: OSpace.m),
                        _playNote(context),
                      ],
                      const SizedBox(height: OSpace.l),
                      Divider(color: c.hairline, height: 1),
                      const SizedBox(height: OSpace.l),
                      _confirmation(context),
                      const SizedBox(height: OSpace.l),
                      OButton(
                        label: data.cancelLabel,
                        variant: OButtonVariant.secondary,
                        expand: true,
                        onPressed: widget.onCancel,
                      ),
                      const SizedBox(height: OSpace.s),
                      Semantics(
                        hint: _canConfirm ? null : data.disabledHint,
                        child: OButton(
                          key: const ValueKey('confirm-typed-button'),
                          label: data.confirmLabel,
                          variant: OButtonVariant.dangerFill,
                          expand: true,
                          onPressed: _canConfirm ? _confirm : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: c.danger.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.warning_amber_rounded, size: 24, color: c.danger),
        ),
        const SizedBox(width: OSpace.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  data.title,
                  style: OType.h2.copyWith(color: c.text),
                ),
              ),
              if (data.irreversibleLabel.isNotEmpty) ...[
                const SizedBox(height: OSpace.xs),
                OPill(label: data.irreversibleLabel, tone: OPillTone.danger),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _removals(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    return Column(
      key: const ValueKey('confirm-typed-removals'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          data.removalsTitle,
          style: OType.bodySm.copyWith(
            color: c.text,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: OSpace.s),
        Container(
          padding: const EdgeInsets.all(OSpace.m),
          decoration: BoxDecoration(
            color: c.danger.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(ORadius.m),
            border: Border.all(color: c.danger.withValues(alpha: 0.22)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < data.removals.length; i++)
                Padding(
                  padding: EdgeInsets.only(
                    bottom: i == data.removals.length - 1 ? 0 : OSpace.s,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.close_rounded, size: 16, color: c.danger),
                      const SizedBox(width: OSpace.s),
                      Expanded(
                        child: Text(
                          data.removals[i],
                          style: OType.bodySm.copyWith(color: c.textMuted),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _graceNote(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      key: const ValueKey('confirm-typed-grace'),
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.accentSoft,
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.restore_rounded, size: 19, color: c.accent),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              widget.data.graceNote,
              style: OType.bodySm.copyWith(color: c.text),
            ),
          ),
        ],
      ),
    );
  }

  Widget _playNote(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    return Container(
      key: const ValueKey('confirm-typed-play-note'),
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.warn.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.shop_outlined, size: 19, color: c.warn),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Text(
                  data.playNote,
                  style: OType.bodySm.copyWith(color: c.text),
                ),
              ),
            ],
          ),
          if (widget.onManageSubscription != null) ...[
            const SizedBox(height: OSpace.s),
            OButton(
              key: const ValueKey('confirm-typed-play-button'),
              label: data.playActionLabel,
              icon: Icons.open_in_new_rounded,
              variant: OButtonVariant.ghost,
              expand: true,
              onPressed: widget.onManageSubscription,
            ),
          ],
        ],
      ),
    );
  }

  Widget _confirmation(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    final email = data.isEmailContact;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          data.prompt,
          style: OType.bodySm.copyWith(
            color: c.text,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: OSpace.s),
        Container(
          key: const ValueKey('confirm-typed-target'),
          padding: const EdgeInsets.all(OSpace.m),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(ORadius.s),
            border: Border.all(color: c.hairlineStrong),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                email ? Icons.mail_outline_rounded : Icons.phone_outlined,
                size: 18,
                color: c.textMuted,
              ),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Text(
                  data.confirmationTarget,
                  style: OType.mono.copyWith(color: c.text),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: OSpace.m),
        TextField(
          key: const ValueKey('confirm-typed-field'),
          controller: _typed,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.none,
          keyboardType: email
              ? TextInputType.emailAddress
              : data.hasContact
              ? TextInputType.phone
              : TextInputType.text,
          autofillHints: data.hasContact
              ? <String>[
                  email ? AutofillHints.email : AutofillHints.telephoneNumber,
                ]
              : null,
          textInputAction: TextInputAction.done,
          style: OType.bodySm.copyWith(color: c.text),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _confirm(),
          decoration: InputDecoration(
            labelText: data.fieldLabel,
            hintText: data.confirmationTarget,
            prefixIcon: Icon(
              email
                  ? Icons.alternate_email_rounded
                  : Icons.phone_iphone_rounded,
              size: 20,
              color: c.textFaint,
            ),
            errorText: _showMismatch ? data.mismatchMessage : null,
            errorMaxLines: 3,
          ),
        ),
        if (_typed.text.isEmpty) ...[
          const SizedBox(height: OSpace.s),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lock_outline_rounded, size: 15, color: c.textFaint),
              const SizedBox(width: OSpace.xs),
              Expanded(
                child: Text(
                  data.lockHint,
                  style: OType.caption.copyWith(color: c.textFaint),
                ),
              ),
            ],
          ),
        ] else if (_matches) ...[
          const SizedBox(height: OSpace.s),
          Semantics(
            liveRegion: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.check_circle_rounded, size: 16, color: c.success),
                const SizedBox(width: OSpace.xs),
                Expanded(
                  child: Text(
                    data.matchedMessage,
                    style: OType.caption.copyWith(color: c.success),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Opens [V2ConfirmTypedSheet] in the shared bottom-sheet container.
///
/// Returns true only when the typed email or phone matched and the person
/// confirmed the irreversible action.
Future<bool> showConfirmTypedSheet(
  BuildContext context, {
  required V2ConfirmTypedSheetData data,
  VoidCallback? onManageSubscription,
}) async {
  final confirmed = await showOSheet<bool>(
    context,
    builder: (sheetContext) => V2ConfirmTypedSheet(
      data: data,
      showHandle: false,
      onManageSubscription: onManageSubscription,
      onConfirm: () => Navigator.of(sheetContext).pop(true),
      onCancel: () => Navigator.of(sheetContext).pop(false),
    ),
  );
  return confirmed ?? false;
}
