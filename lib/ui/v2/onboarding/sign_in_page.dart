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

  /// A provider request is running. The host sets this while the Google
  /// account picker or the phone flow is open.
  final bool loading;

  /// The provider's own failure message, shown verbatim. Cancellation is not
  /// an error: the host maps it to null, and [isCancellation] is a second
  /// guard for hosts that pass the raw sentinel through.
  final String? error;

  bool get isCancellation {
    final value = error?.trim().toLowerCase();
    return value == 'cancelled' || value == 'canceled';
  }
}

/// Which provider the person chose in this build. The host owns the request;
/// this only decides which button paints the in-flight spinner.
enum _SignInProvider { google, phone }

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

  /// Opens the phone flow. Null disables the phone action.
  ///
  /// When [onSendPhoneCode] is also supplied this page hosts
  /// [V2PhoneAuthSheet] and forwards every sheet action to the host. A host
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

  /// The provider the person tapped most recently in this sheet. The host's
  /// [V2SignInData.loading] is a single flag, so this is what keeps the
  /// spinner on the button that started the request instead of on both.
  _SignInProvider? _inflight;
  _SignInProvider? _lastAction;

  @override
  void didUpdateWidget(covariant SignInPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.data.loading) _inflight = null;
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

  void _begin(_SignInProvider provider, VoidCallback? action) {
    if (action == null || widget.data.loading || _inflight != null) return;
    setState(() {
      _inflight = provider;
      _lastAction = provider;
    });
    action();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // A host that opens its own UI may never flip [V2SignInData.loading]
      // (the legacy phone dialog does). Clear the local flag then, so a
      // control cannot stay disabled after the hand-off.
      if (!widget.data.loading && _inflight == provider) {
        setState(() => _inflight = null);
      }
    });
  }

  void _retry() {
    if (widget.data.loading) return;
    final action = _lastAction;
    if (action != null) {
      setState(() => _inflight = action);
    }
    widget.onRetry?.call();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.data.loading && _inflight == action) {
        setState(() => _inflight = null);
      }
    });
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
            onChangeNumber: _changePhoneNumber,
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
    final error = data.isCancellation ? null : data.error;
    // Until the host exposes a per-provider flag, a screen that is busy
    // without a local tap (a retry, or a host that starts in a loading state)
    // keeps the original behaviour: the primary carries the progress.
    final phoneBusy = data.loading && _inflight == _SignInProvider.phone;
    final googleBusy = data.loading && !phoneBusy;

    return OnboardingStepScaffold(
      step: widget.step,
      title: 'Sign in',
      onBack: data.loading ? null : widget.onBack,
      backKey: const Key('sign-in-back'),
      primaryKey: const Key('sign-in-submit'),
      // Google is the filled action, pinned to the same bottom edge as every
      // other step's primary action. The header already says "Sign in", so the
      // label names the provider instead of repeating the title.
      primaryLabel: 'Continue with Google',
      primaryIcon: Icons.g_mobiledata_rounded,
      onPrimary: data.loading || widget.onGoogle == null
          ? null
          : () => _begin(_SignInProvider.google, widget.onGoogle),
      primaryLoading: googleBusy,
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
            loading: phoneBusy,
            onPressed: data.loading || widget.onPhone == null
                ? null
                : () => _begin(_SignInProvider.phone, _openPhoneSheet),
          ),
          if (error != null) ...[
            const SizedBox(height: OSpace.l),
            _InlineError(
              message: error,
              onRetry: widget.onRetry == null || data.loading ? null : _retry,
            ),
          ],
          // The documents live here as well as in Settings: a person creating
          // an account has to be able to read them before choosing a provider.
          const V2LegalNote(key: Key('sign-in-legal')),
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
      key: const Key('sign-in-error'),
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
