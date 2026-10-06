import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/auth_identity.dart';
import '../core/auth_phone_flow.dart';
import '../core/auth_providers.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Shared picker for login, explicit linking, and same-account verification.
///
/// Aether redesign: the picker and its phone-verification dialog are composed
/// from `aether_primitives.dart` so both read as part of the same monochrome
/// surface language as the rest of the app, while the public constructor,
/// callback shape, and underlying flow (busy gating, phone dialog push with
/// `rootNavigator`, `beforePhone` hook, cancellation on dispose, legacy
/// migration help disclosure) are preserved verbatim.
class AuthMethods extends StatefulWidget {
  const AuthMethods({
    super.key,
    required this.providers,
    required this.intent,
    required this.social,
    required this.phone,
    this.linkedIds = const {},
    this.phoneNumber,
    this.onSuccess,
    this.beforePhone,
    this.onBusyChanged,
  });
  final AuthProviders providers;
  final AuthIntent intent;
  final Future<String?> Function(String) social;
  final PhoneAuthFlow Function() phone;
  final Set<String> linkedIds;
  final String? phoneNumber;
  final VoidCallback? onSuccess;
  final Future<String?> Function()? beforePhone;
  final ValueChanged<bool>? onBusyChanged;

  @override
  State<AuthMethods> createState() => _AuthMethodsState();
}

class _AuthMethodsState extends State<AuthMethods> {
  bool _busy = false;
  String? _error;
  bool _helpOpen = false;
  PhoneAuthFlow? _phoneFlow;
  DialogRoute<bool>? _phoneRoute;

  @override
  void dispose() {
    // The dialog is on the navigator, outside this widget's subtree.
    // Invalidate callbacks immediately when its initiating screen disappears.
    _phoneFlow?.cancel(notify: false);
    final route = _phoneRoute;
    final navigator = route?.navigator;
    if (route != null && navigator != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (navigator.mounted && route.isActive) navigator.removeRoute(route);
      });
    }
    super.dispose();
  }

  IconData _iconFor(AuthProviderCapability provider) {
    switch (provider.id) {
      case 'google.com':
        return Icons.account_circle;
      case 'apple.com':
        return Icons.apple;
      case 'github.com':
        return Icons.code;
      case 'phone':
        return Icons.phone_iphone;
      default:
        return Icons.login;
    }
  }

  Future<void> _run(AuthProviderCapability provider) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    widget.onBusyChanged?.call(true);
    String? error;
    try {
      if (provider.isPhone) {
        final verificationError = await widget.beforePhone?.call();
        if (!mounted) return;
        if (verificationError != null) {
          setState(() {
            _busy = false;
            _error = verificationError == 'cancelled'
                ? null
                : verificationError;
          });
          widget.onBusyChanged?.call(false);
          return;
        }
        final flow = _phoneFlow = widget.phone();
        final route = _phoneRoute = DialogRoute<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => AuthPhoneDialog(
            flow: flow,
            fixedNumber: widget.intent == AuthIntent.reauthenticate
                ? widget.phoneNumber
                : null,
          ),
        );
        final result = await Navigator.of(
          context,
          rootNavigator: true,
        ).push(route);
        _phoneFlow = null;
        _phoneRoute = null;
        error = result == true ? null : 'cancelled';
      } else {
        error = await widget.social(provider.id);
      }
    } catch (e) {
      error = authError(e);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error == 'cancelled' ? null : error;
    });
    widget.onBusyChanged?.call(false);
    if (error == null) widget.onSuccess?.call();
  }

  @override
  Widget build(BuildContext context) {
    final choices = widget.providers.enabled
        .where(
          (p) => switch (widget.intent) {
            AuthIntent.signIn => true,
            AuthIntent.link => !widget.linkedIds.contains(p.id),
            AuthIntent.reauthenticate => widget.linkedIds.contains(p.id),
          },
        )
        .toList();
    final prefix = switch (widget.intent) {
      AuthIntent.signIn => 'Continue with',
      AuthIntent.link => 'Link',
      AuthIntent.reauthenticate => 'Verify with',
    };
    final children = <Widget>[];

    if (widget.intent == AuthIntent.signIn) {
      children.add(
        Text(
          'Sign in with a configured social provider or phone. '
          'A new account is created automatically on first sign-in.',
          style: AetherType.body,
        ),
      );
      children.add(const SizedBox(height: 16));
    }

    if (choices.isEmpty) {
      children.add(
        Text(
          'No eligible sign-in methods are configured for this action.',
          style: AetherType.bodyMuted,
        ),
      );
    }

    for (var i = 0; i < choices.length; i++) {
      if (i > 0) children.add(const SizedBox(height: 12));
      final provider = choices[i];
      children.add(
        _AuthAction(
          label: '$prefix ${provider.label}',
          icon: _iconFor(provider),
          onPressed: _busy ? null : () => _run(provider),
        ),
      );
    }

    if (_busy) {
      children.add(const SizedBox(height: 12));
      children.add(
        Text(
          'Complete the authentication prompt to continue.',
          style: AetherType.caption,
        ),
      );
    }

    if (_error != null) {
      children.add(const SizedBox(height: 12));
      children.add(_InlineDangerText(message: _error!));
    }

    if (widget.intent != AuthIntent.reauthenticate) {
      children.add(const SizedBox(height: 16));
      children.add(
        _AuthAction(
          ghost: true,
          label: _helpOpen
              ? 'Hide existing account help'
              : 'Existing account help',
          icon: _helpOpen ? Icons.expand_less : Icons.expand_more,
          onPressed: _busy ? null : () => setState(() => _helpOpen = !_helpOpen),
        ),
      );
      if (_helpOpen) {
        children.add(const SizedBox(height: 8));
        children.add(
          AetherCard(
            title: const Text('Existing account help'),
            padding: const EdgeInsets.all(16),
            child: Text(legacyAuthMigrationHelp, style: AetherType.bodyMuted),
          ),
        );
      }
    }

    return PopScope(
      canPop: !_busy,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

/// Dialog-form of the native OTP flow driven by [PhoneAuthFlow]. The dialog
/// chrome is an [AetherCard] wrapped by a bare [Dialog] so the modal fades
/// with the standard Material transitions while matching the design system.
class AuthPhoneDialog extends StatefulWidget {
  const AuthPhoneDialog({super.key, required this.flow, this.fixedNumber});
  final PhoneAuthFlow flow;
  final String? fixedNumber;
  @override
  State<AuthPhoneDialog> createState() => _AuthPhoneDialogState();
}

class _AuthPhoneDialogState extends State<AuthPhoneDialog> {
  late final _number = TextEditingController(text: widget.fixedNumber ?? '');
  final _code = TextEditingController();
  bool _finished = false;
  int _otpGeneration = 0;

  void _clearCode() {
    _code.clear();
    // The OTP primitive owns its cell controllers. Recreate them even when
    // Firebase delivers codeSent synchronously and no empty-code frame paints.
    setState(() => _otpGeneration++);
  }

  @override
  void initState() {
    super.initState();
    widget.flow.addListener(_changed);
  }

  void _changed() {
    if (!mounted || _finished) return;
    if (widget.flow.succeeded) {
      _finished = true;
      Navigator.of(context).pop(true);
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    widget.flow.removeListener(_changed);
    widget.flow.dispose();
    _number.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final flow = widget.flow;
    final numberEnabled =
        flow.number == null && !flow.submitting && widget.fixedNumber == null;
    final content = <Widget>[
      const AetherSectionTitle(
        eyebrow: 'Verify phone',
        subtitle: 'Verify your number via Firebase SMS.',
      ),
      const SizedBox(height: 12),
      Text(
        'Firebase will send an SMS to verify this number. SMS charges may '
        'apply. Your number is sent to Google for authentication and abuse '
        'prevention.',
        style: AetherType.bodyMuted,
      ),
      const SizedBox(height: 16),
      AetherField(
        label: 'Phone number',
        hint: '+14155550100',
        controller: _number,
        keyboardType: TextInputType.phone,
        autofillHints: const [AutofillHints.telephoneNumber],
        enabled: numberEnabled,
        onSubmitted: numberEnabled ? (_) => flow.send(_number.text) : null,
      ),
    ];

    if (flow.number == null) {
      content.add(const SizedBox(height: 12));
      content.add(
        _AuthAction(
          primary: true,
          label: 'Send code',
          icon: Icons.send,
          loading: flow.sending,
          onPressed: flow.sending || flow.submitting
              ? null
              : () => flow.send(_number.text),
        ),
      );
    }

    if (flow.hasCode) {
      content.add(const SizedBox(height: 16));
      content.add(_buildOtpInput(flow));
      content.add(const SizedBox(height: 12));
      content.add(
        _AuthAction(
          primary: true,
          label: 'Verify code',
          icon: Icons.check,
          loading: flow.submitting,
          onPressed: flow.submitting ? null : () => flow.submit(_code.text),
        ),
      );
    }

    if (flow.number != null) {
      content.add(const SizedBox(height: 12));
      content.add(
        Text(
          flow.hasCode
              ? 'Enter the SMS code, or wait for automatic verification.'
              : flow.error != null
              ? 'Request another code when available, or cancel to try another method.'
              : 'Waiting for SMS verification…',
          style: AetherType.bodyMuted,
        ),
      );
      content.add(const SizedBox(height: 8));
      content.add(
        _AuthAction(
          ghost: true,
          label: flow.cooldown > 0
              ? 'Resend in ${flow.cooldown}s'
              : 'Resend code',
          icon: Icons.refresh,
          onPressed: flow.canResend
              ? () {
                   _clearCode();
                  flow.resend();
                }
              : null,
        ),
      );
      if (widget.fixedNumber == null) {
        content.add(const SizedBox(height: 4));
        content.add(
          _AuthAction(
            ghost: true,
            label: 'Change number',
            icon: Icons.edit,
            onPressed: flow.submitting
                ? null
                : () {
                    flow.cancel();
                     _clearCode();
                  },
          ),
        );
      }
    }

    if (flow.error != null) {
      content.add(const SizedBox(height: 12));
      content.add(_InlineDangerText(message: flow.error!));
    }

    if (flow.sending || flow.submitting) {
      content.add(const SizedBox(height: 12));
      content.add(const LinearProgressIndicator(minHeight: 2));
    }

    content.add(const SizedBox(height: 16));
    content.add(
      Align(
        alignment: Alignment.centerRight,
        child: _AuthAction(
          ghost: true,
          label: 'Cancel',
          onPressed: flow.submitting
              ? null
              : () {
                  flow.cancel();
                  Navigator.of(context).pop(false);
                },
        ),
      ),
    );

    return PopScope(
      canPop: !flow.submitting,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && !_finished) {
          _finished = true;
          flow.cancel();
        }
      },
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: AetherCard(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: content,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Compose fields here: the shared OTP primitive enforces one character before
  // its paste callback and has a fixed cell height. These fields retain full SMS
  // autofill values and wrap without shrinking text on compact dialogs.
  Widget _buildOtpInput(PhoneAuthFlow flow) {
    return _AuthOtpInput(
      key: ValueKey(_otpGeneration),
      enabled: !flow.submitting,
      onChanged: (value) => _code.text = value,
      onSubmitted: () => flow.submit(_code.text),
    );
  }
}

class _AuthOtpInput extends StatefulWidget {
  const _AuthOtpInput({
    super.key,
    required this.enabled,
    required this.onChanged,
    required this.onSubmitted,
  });

  final bool enabled;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;

  @override
  State<_AuthOtpInput> createState() => _AuthOtpInputState();
}

class _AuthOtpInputState extends State<_AuthOtpInput> {
  final _controllers = List.generate(6, (_) => TextEditingController());
  final _focus = List.generate(6, (_) => FocusNode());

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    for (final node in _focus) {
      node.dispose();
    }
    super.dispose();
  }

  void _changed(int index, String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    if (digits.length > 1) {
      // A full SMS replaces the whole code even if a later cell has focus.
      final start = digits.length >= 6 ? 0 : index;
      for (var i = start; i < 6; i++) {
        final offset = i - start;
        _controllers[i].text = offset < digits.length ? digits[offset] : '';
      }
      final next = (start + digits.length).clamp(0, 5);
      _focus[next].requestFocus();
      _controllers[next].selection = TextSelection(
        baseOffset: 0, extentOffset: _controllers[next].text.length,
      );
    } else {
      _controllers[index].value = TextEditingValue(
        text: digits,
        selection: TextSelection.collapsed(offset: digits.length),
      );
      if (digits.isNotEmpty && index < 5) {
        _focus[index + 1].requestFocus();
        _controllers[index + 1].selection = TextSelection(
          baseOffset: 0, extentOffset: _controllers[index + 1].text.length,
        );
      }
    }
    // Preserve empty positions so a gap can never become a valid six-digit code.
    widget.onChanged(_controllers.map((c) => c.text.isEmpty ? ' ' : c.text).join());
  }

  @override
  Widget build(BuildContext context) {
    final cellWidth = MediaQuery.textScalerOf(context).scale(14) + 24;
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('SMS code', style: AetherType.label),
          const SizedBox(height: 8),
          LayoutBuilder(builder: (context, constraints) {
            final columns = constraints.maxWidth >= cellWidth * 6 + 40 ? 6 : 3;
            final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < 6; i++)
                  SizedBox(
                    width: width,
                    child: Semantics(
                      label: 'SMS code digit ${i + 1} of 6',
                      child: Focus(
                        onKeyEvent: (_, event) {
                          if (widget.enabled && event is KeyDownEvent &&
                              event.logicalKey == LogicalKeyboardKey.backspace &&
                              _controllers[i].text.isEmpty && i > 0) {
                            _focus[i - 1].requestFocus();
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: AetherField(
                          label: 'SMS code digit ${i + 1} of 6',
                          showLabel: false,
                          controller: _controllers[i],
                          focusNode: _focus[i],
                          enabled: widget.enabled,
                          keyboardType: TextInputType.number,
                          autofillHints: i == 0 ? const [AutofillHints.oneTimeCode] : null,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          onChanged: (value) => _changed(i, value),
                          onSubmitted: (_) => widget.onSubmitted(),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          }),
        ],
      ),
    );
  }
}

/// Retain the standard primitive when its label fits; otherwise allow a taller,
/// wrapping action using the same Aether tokens instead of clipping large text.
class _AuthAction extends StatelessWidget {
  const _AuthAction({
    required this.label,
    this.icon,
    this.onPressed,
    this.loading = false,
    this.primary = false,
    this.ghost = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool loading;
  final bool primary;
  final bool ghost;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 14, fontWeight: FontWeight.w600);
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    // Avoid LayoutBuilder here: the picker also lives in AlertDialog's
    // intrinsically measured content. Use a conservative compact-dialog width.
    final availableWidth = (MediaQuery.sizeOf(context).width - 128).clamp(0.0, 280.0);
    final fits = painter.width + 32 + (icon == null ? 0 : 24) <= availableWidth &&
        painter.height <= 28;
    painter.dispose();
    if (fits) {
      if (primary) {
        return AetherPrimaryButton(label: label, icon: icon,
          onPressed: onPressed, loading: loading);
      }
      if (ghost) {
        return AetherGhostButton(label: label, icon: icon,
          onPressed: onPressed, loading: loading);
      }
      return AetherSecondaryButton(label: label, icon: icon,
        onPressed: onPressed, loading: loading);
    }
    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading) ...[
          const SizedBox(width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 8),
        ] else if (icon != null) ...[
          Icon(icon, size: 16),
          const SizedBox(width: 8),
        ],
        Flexible(child: Text(label, style: style, textAlign: TextAlign.center)),
      ],
    );
    final buttonStyle = TextButton.styleFrom(
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      foregroundColor: primary ? Colors.white : (ghost ? Aether.textMuted : Aether.text),
      backgroundColor: primary ? Aether.accent : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AetherRadius.rMd)),
      side: !primary && !ghost ? BorderSide(color: Aether.hairlineStrong) : null,
    );
    final callback = loading ? null : onPressed;
    if (primary) return FilledButton(style: buttonStyle, onPressed: callback, child: child);
    if (ghost) return TextButton(style: buttonStyle, onPressed: callback, child: child);
    return OutlinedButton(style: buttonStyle, onPressed: callback, child: child);
  }
}

/// Inline danger panel: left bar + muted text block.
class _InlineDangerText extends StatelessWidget {
  const _InlineDangerText({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Aether.danger.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AetherRadius.rSm),
          border: Border(
            left: BorderSide(color: Aether.dangerC, width: 3),
          ),
        ),
        child: Text(
          message,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Aether.dangerC,
          ),
        ),
      ),
    );
  }
}
