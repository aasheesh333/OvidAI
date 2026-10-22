import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'phone_auth_sheet.dart';
import 'step_progress.dart';

// TODO(l10n): move sign-in copy to the ARB files.

/// Injected state for the sign-in form. The screen never reads a session or a
/// network client; the wiring layer supplies values and receives callbacks.
@immutable
class V2SignInData {
  const V2SignInData({
    this.email = '',
    this.password = '',
    this.language = 'English',
    this.loading = false,
    this.error,
  });

  final String email;
  final String password;
  final String language;
  final bool loading;
  final String? error;
}

/// Third step of the tour. Same shell as every other step: one header, the
/// step indicator, a scrolling form and the primary action pinned at the
/// bottom.
class SignInPage extends StatefulWidget {
  const SignInPage({
    super.key,
    this.data = const V2SignInData(),
    this.onEmailChanged,
    this.onPasswordChanged,
    this.onSubmit,
    this.onGoogle,
    this.onPhone,
    this.phoneData,
    this.onPhoneChanged,
    this.onPhoneCountryChanged,
    this.onSendPhoneCode,
    this.onVerifyPhoneCode,
    this.onResendPhoneCode,
    this.onChangePhoneNumber,
    this.onApple,
    this.onForgotPassword,
    this.onCreateAccount,
    this.onLanguageTap,
    this.onTerms,
    this.onPrivacy,
    this.onRetry,
    this.onBack,
    this.step = const V2OnboardingStepData(
      step: V2OnboardingTour.signIn,
      totalSteps: V2OnboardingTour.totalSteps,
      trailingLabel: '',
    ),
  });

  final V2SignInData data;
  final ValueChanged<String>? onEmailChanged;
  final ValueChanged<String>? onPasswordChanged;
  final void Function(String email, String password)? onSubmit;
  final VoidCallback? onGoogle;

  /// Opens [V2PhoneAuthSheet]. Null disables the phone action.
  ///
  /// The sheet is only used when the host drives it through
  /// [onSendPhoneCode]; the send / verify / resend actions then forward to
  /// [onSendPhoneCode], [onVerifyPhoneCode] and [onResendPhoneCode]. A host
  /// that only supplies [onPhone] owns its own OTP UI, so this button invokes
  /// it directly instead of asking for the number twice.
  final VoidCallback? onPhone;

  /// Host-owned sheet state: which step is showing, loading, errors and the
  /// resend countdown. Null shows the phone-number step.
  final V2PhoneAuthData? phoneData;

  final ValueChanged<String>? onPhoneChanged;
  final ValueChanged<V2PhoneCountry>? onPhoneCountryChanged;

  /// Sends a code to the national number the person typed.
  final ValueChanged<String>? onSendPhoneCode;

  /// Verifies the six-digit code.
  final ValueChanged<String>? onVerifyPhoneCode;

  final VoidCallback? onResendPhoneCode;

  /// Returns the sheet to the number step. The host owns [phoneData]; when no
  /// callback is wired the sheet clears the code locally.
  final VoidCallback? onChangePhoneNumber;

  final VoidCallback? onApple;
  final VoidCallback? onForgotPassword;
  final VoidCallback? onCreateAccount;
  final VoidCallback? onLanguageTap;

  /// Opens the legal documents. When null the labels stay plain text instead
  /// of looking like links that do nothing.
  final VoidCallback? onTerms;
  final VoidCallback? onPrivacy;

  /// Re-runs the failed attempt. Only supplied when there is something to
  /// retry: a generic message with no recovery path shows no "Try again".
  final VoidCallback? onRetry;

  /// When supplied, the header's back action returns to the previous
  /// onboarding step instead of popping a route that may not exist.
  final VoidCallback? onBack;

  final V2OnboardingStepData step;

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  late final TextEditingController _email = TextEditingController(
    text: widget.data.email,
  );
  late final TextEditingController _password = TextEditingController(
    text: widget.data.password,
  );
  bool _obscure = true;

  /// Mirrors the host's [SignInPage.phoneData] into the open sheet route. A
  /// modal bottom sheet does not rebuild with its opener, so the page pushes
  /// later host updates through this notifier.
  final ValueNotifier<V2PhoneAuthData> _phoneSheet = ValueNotifier(
    const V2PhoneAuthData(),
  );
  bool _phoneSheetOpen = false;

  @override
  void didUpdateWidget(covariant SignInPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data.email != oldWidget.data.email &&
        widget.data.email != _email.text) {
      _email.text = widget.data.email;
    }
    if (widget.data.password != oldWidget.data.password &&
        widget.data.password != _password.text) {
      _password.text = widget.data.password;
    }
    if (_phoneSheetOpen) {
      final next = widget.phoneData ?? const V2PhoneAuthData();
      final previous = oldWidget.phoneData ?? const V2PhoneAuthData();
      if (!_samePhoneData(next, previous)) {
        // The page can rebuild inside a build phase; notify the sheet route
        // after the frame instead of dirtying it mid-build.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _phoneSheetOpen) {
            _phoneSheet.value = next;
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _phoneSheet.dispose();
    super.dispose();
  }

  void _submit() {
    widget.onSubmit?.call(_email.text.trim(), _password.text);
  }

  Future<void> _openPhoneSheet() async {
    if (widget.onPhone == null || _phoneSheetOpen) return;
    // A host that does not drive the sheet owns its own OTP flow. Opening a
    // number sheet here would collect the number and then hand over to a
    // second flow that asks for it again.
    if (widget.onSendPhoneCode == null) {
      widget.onPhone!.call();
      return;
    }
    _phoneSheet.value = widget.phoneData ?? const V2PhoneAuthData();
    _phoneSheetOpen = true;
    try {
      await showOSheet<void>(
        context,
        builder: (sheetContext) => ValueListenableBuilder<V2PhoneAuthData>(
          valueListenable: _phoneSheet,
          builder: (context, data, _) => V2PhoneAuthSheet(
            data: data,
            showHandle: false,
            onCountryChanged: widget.onPhoneCountryChanged,
            onPhoneChanged: widget.onPhoneChanged,
            onSendCode: (phone) => widget.onSendPhoneCode?.call(phone),
            onVerify: widget.onVerifyPhoneCode,
            onResend: widget.onResendPhoneCode,
            onChangeNumber: () => _changePhoneNumber(),
            onClose: () => Navigator.of(sheetContext).pop(),
          ),
        ),
      );
    } finally {
      _phoneSheetOpen = false;
    }
  }

  void _changePhoneNumber() {
    final change = widget.onChangePhoneNumber;
    if (change != null) {
      change();
      return;
    }
    final data = _phoneSheet.value;
    _phoneSheet.value = V2PhoneAuthData(
      country: data.country,
      phone: data.phone,
      countries: data.countries,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    return OnboardingStepScaffold(
      step: widget.step,
      title: 'Sign in',
      subtitle: 'Welcome back',
      onBack: widget.onBack,
      backKey: const Key('sign-in-back'),
      dismissKeyboard: true,
      primaryKey: const Key('sign-in-submit'),
      // The header already says "Sign in"; repeating it on the button would
      // be the same string twice on one screen.
      primaryLabel: 'Continue',
      onPrimary: data.loading || widget.onSubmit == null ? null : _submit,
      primaryLoading: data.loading,
      secondaryActions: [
        OTextAction(
          label: 'Create an account',
          onPressed: data.loading ? null : widget.onCreateAccount,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: OnboardingLanguagePill(
              key: const Key('sign-in-language'),
              label: data.language,
              onTap: data.loading ? null : widget.onLanguageTap,
            ),
          ),
          const SizedBox(height: OSpace.l),
          OButton(
            label: 'Continue with Google',
            variant: OButtonVariant.secondary,
            icon: Icons.g_mobiledata_rounded,
            expand: true,
            onPressed: data.loading ? null : widget.onGoogle,
          ),
          const SizedBox(height: OSpace.m),
          OButton(
            key: const Key('sign-in-phone'),
            label: 'Continue with phone',
            variant: OButtonVariant.secondary,
            icon: Icons.phone_iphone_rounded,
            expand: true,
            onPressed: data.loading || widget.onPhone == null
                ? null
                : _openPhoneSheet,
          ),
          const SizedBox(height: OSpace.m),
          // Apple is only rendered when a real handler exists. A provider this
          // build cannot complete is not offered at all.
          if (widget.onApple != null) ...[
            OButton(
              label: 'Continue with Apple',
              variant: OButtonVariant.secondary,
              icon: Icons.apple_rounded,
              expand: true,
              onPressed: data.loading ? null : widget.onApple,
            ),
            const SizedBox(height: OSpace.m),
          ],
          const SizedBox(height: OSpace.l),
          const ODivider(label: 'OR'),
          const SizedBox(height: OSpace.l),
          _FieldLabel(label: 'Email address', color: c.textMuted),
          const SizedBox(height: OSpace.s),
          Semantics(
            label: 'Email address',
            textField: true,
            child: TextField(
              key: const Key('sign-in-email'),
              controller: _email,
              enabled: !data.loading,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.email],
              onChanged: widget.onEmailChanged,
              style: OType.body.copyWith(color: c.text),
              decoration: const InputDecoration(hintText: 'you@domain.com'),
            ),
          ),
          const SizedBox(height: OSpace.l),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: OSpace.s,
            runSpacing: OSpace.xs,
            children: [
              _FieldLabel(label: 'Password', color: c.textMuted),
              OButton(
                label: 'Forgot password?',
                variant: OButtonVariant.ghost,
                onPressed: data.loading ? null : widget.onForgotPassword,
              ),
            ],
          ),
          const SizedBox(height: OSpace.s),
          Semantics(
            label: 'Password',
            textField: true,
            child: TextField(
              key: const Key('sign-in-password'),
              controller: _password,
              enabled: !data.loading,
              obscureText: _obscure,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.password],
              onChanged: widget.onPasswordChanged,
              onSubmitted: (_) => _submit(),
              style: OType.body.copyWith(color: c.text),
              decoration: InputDecoration(
                hintText: 'Your password',
                suffixIcon: OIconButton(
                  key: const Key('sign-in-password-toggle'),
                  icon: _obscure
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
                  semanticLabel: _obscure ? 'Show password' : 'Hide password',
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                  onPressed: data.loading
                      ? null
                      : () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
          ),
          if (data.error != null) ...[
            const SizedBox(height: OSpace.l),
            _InlineError(message: data.error!, onRetry: widget.onRetry),
          ],
          const SizedBox(height: OSpace.l),
          // Underlining is a promise of a tap. Without a handler the sentence
          // stays plain text instead of faking a link.
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'By signing in, you agree to our ',
                style: OType.caption.copyWith(color: c.textMuted),
              ),
              _LegalLink(label: 'Terms', onTap: widget.onTerms),
              Text(' and ', style: OType.caption.copyWith(color: c.textMuted)),
              _LegalLink(label: 'Privacy Policy', onTap: widget.onPrivacy),
              Text('.', style: OType.caption.copyWith(color: c.textMuted)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Compares the host-owned sheet state field by field. [V2PhoneAuthData] has
/// no `==`, and rebuilding on every parent frame would fight the sheet's own
/// step changes.
bool _samePhoneData(V2PhoneAuthData a, V2PhoneAuthData b) {
  if (identical(a, b)) return true;
  if (a.step != b.step ||
      a.phone != b.phone ||
      a.code != b.code ||
      a.loading != b.loading ||
      a.error != b.error ||
      a.resendSeconds != b.resendSeconds ||
      a.country.region != b.country.region ||
      a.country.dialCode != b.country.dialCode ||
      a.countries.length != b.countries.length) {
    return false;
  }
  for (var i = 0; i < a.countries.length; i++) {
    if (a.countries[i].region != b.countries[i].region ||
        a.countries[i].dialCode != b.countries[i].dialCode) {
      return false;
    }
  }
  return true;
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(label, style: OType.label.copyWith(color: color));
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          OSpace.m,
          OSpace.s,
          OSpace.m,
          OSpace.s,
        ),
        decoration: BoxDecoration(
          color: c.danger.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(ORadius.m),
          border: Border.all(color: c.danger.withValues(alpha: 0.40)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                Icons.error_outline_rounded,
                size: 20,
                color: c.danger,
              ),
            ),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message, style: OType.bodySm.copyWith(color: c.danger)),
                  if (onRetry != null) ...[
                    const SizedBox(height: OSpace.xs),
                    OButton(
                      label: 'Try again',
                      variant: OButtonVariant.ghost,
                      onPressed: onRetry,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline legal link with a 48 dp tap target. Without [onTap] it degrades to
/// plain text, never a dead underline.
class _LegalLink extends StatelessWidget {
  const _LegalLink({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final text = Text(
      label,
      style: OType.caption.copyWith(
        color: onTap == null ? c.textMuted : c.text,
        decoration: onTap == null ? null : TextDecoration.underline,
        decorationColor: c.textMuted,
      ),
    );
    if (onTap == null) return text;
    return Semantics(
      container: true,
      label: label,
      button: true,
      onTap: onTap,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: OSpace.touch),
            child: Center(widthFactor: 1, heightFactor: 1, child: text),
          ),
        ),
      ),
    );
  }
}
