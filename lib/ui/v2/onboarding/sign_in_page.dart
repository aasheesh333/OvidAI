import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_tokens.dart';
import 'phone_auth_sheet.dart';
import 'step_progress.dart';

// TODO(l10n): move sign-in copy to the ARB files.

/// Injected state for the sign-in step. The screen never reads a session or a
/// network client; the wiring layer supplies values and receives callbacks.
@immutable
class V2SignInData {
  const V2SignInData({this.loading = false, this.error});

  final bool loading;
  final String? error;
}

/// Third step of the tour. Same shell as every other step: one header, the
/// step indicator, a scrolling body and the primary action pinned at the
/// bottom. The body is the shared identity, one line, and the secondary
/// provider; Google is the filled primary on the bottom edge.
///
/// The product has exactly two auth providers: Google and phone. There is no
/// email/password backend, so the step renders no email form and no Apple
/// button — a control that cannot reach a real service is removed, not
/// disabled (MINIMAL_UI_CONTRACT §8).
class SignInPage extends StatefulWidget {
  const SignInPage({
    super.key,
    this.data = const V2SignInData(),
    this.onGoogle,
    this.onPhone,
    this.phoneData,
    this.onPhoneChanged,
    this.onPhoneCountryChanged,
    this.onSendPhoneCode,
    this.onVerifyPhoneCode,
    this.onResendPhoneCode,
    this.onChangePhoneNumber,
    this.onRetry,
    this.onBack,
    this.step = const V2OnboardingStepData(
      step: V2OnboardingTour.signIn,
      totalSteps: V2OnboardingTour.totalSteps,
      trailingLabel: '',
    ),
  });

  final V2SignInData data;
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
    _phoneSheet.dispose();
    super.dispose();
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
    final data = widget.data;
    return OnboardingStepScaffold(
      step: widget.step,
      title: 'Sign in',
      onBack: widget.onBack,
      backKey: const Key('sign-in-back'),
      primaryKey: const Key('sign-in-submit'),
      // Google is the filled action, pinned to the same bottom edge as every
      // other step's primary action. The header already says "Sign in", so the
      // label names the provider instead of repeating the title.
      primaryLabel: 'Continue with Google',
      primaryIcon: Icons.g_mobiledata_rounded,
      onPrimary: data.loading || widget.onGoogle == null
          ? null
          : widget.onGoogle,
      primaryLoading: data.loading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(
            child: Padding(
              padding: EdgeInsets.only(top: OSpace.m, bottom: OSpace.xl),
              child: OnboardingIdentity(line: 'Welcome back'),
            ),
          ),
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
          if (data.error != null) ...[
            const SizedBox(height: OSpace.l),
            _InlineError(message: data.error!, onRetry: widget.onRetry),
          ],
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
