import 'package:flutter/material.dart';
import '../core/auth_identity.dart';
import '../core/auth_phone_flow.dart';
import '../core/auth_providers.dart';

/// Shared picker for login, explicit linking, and same-account verification.
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
    return PopScope(
      canPop: !_busy,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.intent == AuthIntent.signIn) ...[
            const Text(
              'Sign in with a configured social provider or phone. A new account is created automatically on first sign-in.',
            ),
            const SizedBox(height: 12),
          ],
          if (choices.isEmpty)
            const Text(
              'No eligible sign-in methods are configured for this action.',
            ),
          for (final provider in choices)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: OutlinedButton(
                onPressed: _busy ? null : () => _run(provider),
                child: Text('$prefix ${provider.label}'),
              ),
            ),
          if (_busy)
            const Text('Complete the authentication prompt to continue.'),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (widget.intent != AuthIntent.reauthenticate)
            const ExpansionTile(
              title: Text('Existing account help'),
              children: [
                Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(legacyAuthMigrationHelp),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

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
    return PopScope(
      canPop: !flow.submitting,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && !_finished) {
          _finished = true;
          flow.cancel();
        }
      },
      child: AlertDialog(
        title: const Text('Verify phone'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Firebase will send an SMS to verify this number. SMS charges may apply. Your number is sent to Google for authentication and abuse prevention.',
              ),
              TextField(
                controller: _number,
                keyboardType: TextInputType.phone,
                enabled:
                    flow.number == null &&
                    !flow.submitting &&
                    widget.fixedNumber == null,
                autofillHints: const [AutofillHints.telephoneNumber],
                decoration: const InputDecoration(
                  labelText: 'Phone number',
                  hintText: '+14155550100',
                ),
              ),
              if (flow.number == null)
                FilledButton(
                  onPressed: flow.sending || flow.submitting
                      ? null
                      : () => flow.send(_number.text),
                  child: const Text('Send code'),
                ),
              if (flow.hasCode) ...[
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  enabled: !flow.submitting,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  decoration: const InputDecoration(labelText: 'SMS code'),
                  onSubmitted: (_) => flow.submit(_code.text),
                ),
                FilledButton(
                  onPressed: flow.submitting
                      ? null
                      : () => flow.submit(_code.text),
                  child: const Text('Verify code'),
                ),
              ],
              if (flow.number != null) ...[
                Text(
                  flow.hasCode
                      ? 'Enter the SMS code, or wait for automatic verification.'
                      : 'Waiting for SMS verification…',
                ),
                TextButton(
                  onPressed: flow.canResend
                      ? () {
                          _code.clear();
                          flow.resend();
                        }
                      : null,
                  child: Text(
                    flow.cooldown > 0
                        ? 'Resend in ${flow.cooldown}s'
                        : 'Resend code',
                  ),
                ),
                if (widget.fixedNumber == null)
                  TextButton(
                    onPressed: flow.submitting
                        ? null
                        : () {
                            flow.cancel();
                            _code.clear();
                          },
                    child: const Text('Change number'),
                  ),
              ],
              if (flow.error != null)
                Text(
                  flow.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (flow.sending || flow.submitting)
                const LinearProgressIndicator(),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: flow.submitting
                ? null
                : () {
                    flow.cancel();
                    Navigator.of(context).pop(false);
                  },
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}
