import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move phone sign-in copy and country names to the ARB files.

/// A country calling code offered by the phone sign-in sheet.
///
/// Kept in the presentation layer so the sheet has no dependency on Firebase
/// or the auth store. The wiring layer may inject its own list through
/// [V2PhoneAuthData.countries].
@immutable
class V2PhoneCountry {
  const V2PhoneCountry({
    required this.region,
    required this.dialCode,
    required this.name,
    required this.example,
  });

  /// ISO 3166-1 alpha-2 region, e.g. `IN`.
  final String region;

  /// Calling code with the leading `+`, e.g. `+91`.
  final String dialCode;

  final String name;

  /// A national-format example used as the phone field hint.
  final String example;

  String get label => '$name $dialCode';
}

/// India first: it is Ovid's primary market and the fallback region.
const List<V2PhoneCountry> kV2PhoneCountries = <V2PhoneCountry>[
  V2PhoneCountry(
    region: 'IN',
    dialCode: '+91',
    name: 'India',
    example: '98765 43210',
  ),
  V2PhoneCountry(
    region: 'US',
    dialCode: '+1',
    name: 'United States',
    example: '415 555 0100',
  ),
  V2PhoneCountry(
    region: 'CA',
    dialCode: '+1',
    name: 'Canada',
    example: '604 555 0100',
  ),
  V2PhoneCountry(
    region: 'GB',
    dialCode: '+44',
    name: 'United Kingdom',
    example: '7700 900123',
  ),
  V2PhoneCountry(
    region: 'AE',
    dialCode: '+971',
    name: 'United Arab Emirates',
    example: '50 123 4567',
  ),
  V2PhoneCountry(
    region: 'SA',
    dialCode: '+966',
    name: 'Saudi Arabia',
    example: '51 234 5678',
  ),
  V2PhoneCountry(
    region: 'SG',
    dialCode: '+65',
    name: 'Singapore',
    example: '8123 4567',
  ),
  V2PhoneCountry(
    region: 'MY',
    dialCode: '+60',
    name: 'Malaysia',
    example: '12 345 6789',
  ),
  V2PhoneCountry(
    region: 'NP',
    dialCode: '+977',
    name: 'Nepal',
    example: '984 1234567',
  ),
  V2PhoneCountry(
    region: 'BD',
    dialCode: '+880',
    name: 'Bangladesh',
    example: '1812 345678',
  ),
  V2PhoneCountry(
    region: 'LK',
    dialCode: '+94',
    name: 'Sri Lanka',
    example: '71 234 5678',
  ),
  V2PhoneCountry(
    region: 'PK',
    dialCode: '+92',
    name: 'Pakistan',
    example: '301 2345678',
  ),
  V2PhoneCountry(
    region: 'AU',
    dialCode: '+61',
    name: 'Australia',
    example: '412 345 678',
  ),
  V2PhoneCountry(
    region: 'DE',
    dialCode: '+49',
    name: 'Germany',
    example: '1512 3456789',
  ),
  V2PhoneCountry(
    region: 'FR',
    dialCode: '+33',
    name: 'France',
    example: '6 12 34 56 78',
  ),
];

/// The default country: India.
const V2PhoneCountry _defaultCountry = V2PhoneCountry(
  region: 'IN',
  dialCode: '+91',
  name: 'India',
  example: '98765 43210',
);

/// Which half of the phone sign-in flow the sheet is showing.
enum V2PhoneAuthStep { phone, code }

/// Injected state for the phone sign-in sheet.
///
/// The resend countdown is owned by the auth controller and passed in, exactly
/// like the take-control countdown: one source of truth, no timer inside a
/// presentational widget. [code] must already be at most six digits.
@immutable
class V2PhoneAuthData {
  const V2PhoneAuthData({
    this.step = V2PhoneAuthStep.phone,
    this.country = _defaultCountry,
    this.phone = '',
    this.code = '',
    this.loading = false,
    this.error,
    this.resendSeconds = 0,
    this.countries = kV2PhoneCountries,
  });

  final V2PhoneAuthStep step;
  final V2PhoneCountry country;
  final String phone;
  final String code;

  /// A send or verify request is in flight.
  final bool loading;

  /// Inline error for the current step (invalid number, wrong code, no SMS).
  final String? error;

  /// Seconds until another SMS may be requested. `0` enables resend.
  final int resendSeconds;

  final List<V2PhoneCountry> countries;

  /// The number exactly as it will be shown back to the person.
  String get displayNumber {
    final trimmed = phone.trim();
    return trimmed.isEmpty ? country.dialCode : '${country.dialCode} $trimmed';
  }

  bool get canResend => resendSeconds <= 0 && !loading;
}

/// Bottom sheet for signing in with a phone number and a six-digit SMS code.
///
/// Presentational only: every value comes from [data] and every action leaves
/// through a callback. Host it with `showOSheet(..., showHandle: false)`
/// because the sheet draws its own grabber by default.
class V2PhoneAuthSheet extends StatefulWidget {
  const V2PhoneAuthSheet({
    super.key,
    this.data = const V2PhoneAuthData(),
    this.onCountryChanged,
    this.onPhoneChanged,
    this.onSendCode,
    this.onCodeChanged,
    this.onVerify,
    this.onResend,
    this.onChangeNumber,
    this.onClose,
    this.onRetry,
    this.onTerms,
    this.onPrivacy,
    this.showHandle = true,
  });

  final V2PhoneAuthData data;
  final ValueChanged<V2PhoneCountry>? onCountryChanged;
  final ValueChanged<String>? onPhoneChanged;

  /// Called with the national number as typed (the selected dial code is in
  /// [V2PhoneAuthData.country]).
  final ValueChanged<String>? onSendCode;

  final ValueChanged<String>? onCodeChanged;

  /// Called with the six-digit code once the person confirms.
  final ValueChanged<String>? onVerify;

  final VoidCallback? onResend;

  /// Returns to the number step without closing the sheet.
  final VoidCallback? onChangeNumber;
  final VoidCallback? onClose;

  /// Re-runs the failed request. Falls back to the primary action.
  final VoidCallback? onRetry;

  final VoidCallback? onTerms;
  final VoidCallback? onPrivacy;

  /// Set false when [showOSheet] already draws the grabber.
  final bool showHandle;

  @override
  State<V2PhoneAuthSheet> createState() => _V2PhoneAuthSheetState();
}

class _V2PhoneAuthSheetState extends State<V2PhoneAuthSheet> {
  late final TextEditingController _phone = TextEditingController(
    text: widget.data.phone,
  );
  late final TextEditingController _code = TextEditingController(
    text: widget.data.code,
  );
  final FocusNode _codeFocus = FocusNode();

  @override
  void didUpdateWidget(covariant V2PhoneAuthSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data.phone != oldWidget.data.phone &&
        widget.data.phone != _phone.text) {
      _phone.text = widget.data.phone;
    }
    if (widget.data.code != oldWidget.data.code &&
        widget.data.code != _code.text) {
      _code.text = widget.data.code;
    }
    if (widget.data.step == V2PhoneAuthStep.phone &&
        oldWidget.data.step != V2PhoneAuthStep.phone) {
      _code.clear();
      _codeFocus.unfocus();
    }
  }

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  bool get _busy => widget.data.loading;

  bool get _isCode => widget.data.step == V2PhoneAuthStep.code;

  bool get _canSend => widget.onSendCode != null && !_busy;
  bool get _canVerify => widget.onVerify != null && !_busy;
  bool get _canRetry =>
      widget.onRetry != null || (_isCode ? _canVerify : _canSend);

  void _send() {
    if (_busy || widget.onSendCode == null) return;
    final phone = _phone.text.trim();
    if (phone.isEmpty) return;
    widget.onSendCode!(phone);
  }

  void _verify() {
    if (_busy || widget.onVerify == null) return;
    final code = _code.text.trim();
    if (code.length != 6) return;
    widget.onVerify!(code);
  }

  void _retry() {
    final retry = widget.onRetry;
    if (retry != null) {
      retry();
    } else if (_isCode && _canVerify) {
      _verify();
    } else if (!_isCode && _canSend) {
      _send();
    }
  }

  Future<void> _pickCountry() async {
    if (_busy || widget.onCountryChanged == null) return;
    final selected = await showOSheet<V2PhoneCountry>(
      context,
      title: 'Country code',
      builder: (_) => _CountryPickerSheet(
        countries: widget.data.countries,
        selected: widget.data.country,
      ),
    );
    if (selected != null && selected.region != widget.data.country.region) {
      widget.onCountryChanged?.call(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    final isCode = data.step == V2PhoneAuthStep.code;

    return Column(
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
            padding: const EdgeInsets.fromLTRB(
              OSpace.xl,
              OSpace.l,
              OSpace.xl,
              OSpace.xl,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: OFadeSlide(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OSheetHeader(
                        leading: isCode
                            ? OIconButton(
                                key: const Key('phone-auth-back'),
                                icon: Icons.arrow_back_rounded,
                                semanticLabel: 'Change number',
                                tooltip: 'Change number',
                                onPressed: isCode && !_busy
                                    ? (widget.onChangeNumber ?? widget.onClose)
                                    : null,
                              )
                            : Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: c.accentSoft,
                                  borderRadius: BorderRadius.circular(
                                    ORadius.m,
                                  ),
                                ),
                                child: Icon(
                                  Icons.phone_iphone_rounded,
                                  size: 20,
                                  color: c.accent,
                                ),
                              ),
                        onClose: widget.onClose,
                        closeLabel: 'Close',
                        closeKey: const Key('phone-auth-close'),
                        padding: EdgeInsets.zero,
                      ),
                      const SizedBox(height: OSpace.l),
                      Text(
                        isCode ? 'Enter your code' : 'Sign in with your phone',
                        style: OType.h1.copyWith(color: c.text),
                      ),
                      const SizedBox(height: OSpace.s),
                      if (isCode)
                        _CodeSubtitle(
                          number: data.displayNumber,
                          onChangeNumber: _busy ? null : widget.onChangeNumber,
                        )
                      else
                        Text(
                          'We will text you a 6-digit code. Standard message '
                          'rates may apply.',
                          style: OType.bodySm.copyWith(color: c.textMuted),
                        ),
                      const SizedBox(height: OSpace.xl),
                      if (isCode)
                        _CodeFields(
                          data: data,
                          controller: _code,
                          focusNode: _codeFocus,
                          onChanged: (value) {
                            setState(() {});
                            widget.onCodeChanged?.call(value);
                          },
                          onSubmitted: _verify,
                        )
                      else
                        _PhoneFields(
                          data: data,
                          controller: _phone,
                          countryEnabled:
                              !_busy && widget.onCountryChanged != null,
                          onPickCountry: _pickCountry,
                          onChanged: (value) {
                            setState(() {});
                            widget.onPhoneChanged?.call(value);
                          },
                          onSubmitted: _send,
                        ),
                      if (data.error != null) ...[
                        const SizedBox(height: OSpace.l),
                        _SheetError(
                          message: data.error!,
                          onRetry: _busy || !_canRetry ? null : _retry,
                        ),
                      ],
                      if (isCode) ...[
                        const SizedBox(height: OSpace.l),
                        _ResendRow(
                          data: data,
                          onResend: _busy ? null : widget.onResend,
                        ),
                      ],
                      const SizedBox(height: OSpace.xl),
                      OButton(
                        key: Key(
                          isCode ? 'phone-auth-verify' : 'phone-auth-send',
                        ),
                        label: isCode
                            ? (data.loading
                                  ? 'Verifying…'
                                  : 'Verify and continue')
                            : (data.loading ? 'Sending code…' : 'Send code'),
                        icon: isCode
                            ? Icons.arrow_forward_rounded
                            : Icons.sms_outlined,
                        expand: true,
                        loading: data.loading,
                        onPressed: _busy
                            ? null
                            : (isCode
                                  ? (_code.text.trim().length == 6 &&
                                            _canVerify
                                        ? _verify
                                        : null)
                                  : (_phone.text.trim().isNotEmpty &&
                                            _canSend
                                        ? _send
                                        : null)),
                      ),
                      if (!isCode) ...[
                        const SizedBox(height: OSpace.l),
                        _TermsNote(
                          onTerms: widget.onTerms,
                          onPrivacy: widget.onPrivacy,
                        ),
                      ] else ...[
                        const SizedBox(height: OSpace.m),
                        Text(
                          'Codes expire after 5 minutes. Never share your code '
                          'with anyone.',
                          textAlign: TextAlign.center,
                          style: OType.caption.copyWith(color: c.textFaint),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PhoneFields extends StatelessWidget {
  const _PhoneFields({
    required this.data,
    required this.controller,
    required this.countryEnabled,
    required this.onPickCountry,
    this.onChanged,
    this.onSubmitted,
  });

  final V2PhoneAuthData data;
  final TextEditingController controller;
  final bool countryEnabled;
  final VoidCallback onPickCountry;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Phone number', style: OType.label.copyWith(color: c.textMuted)),
        const SizedBox(height: OSpace.s),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CountryButton(
              country: data.country,
              enabled: countryEnabled,
              onTap: onPickCountry,
            ),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Semantics(
                label: 'Phone number, ${data.country.name}',
                textField: true,
                child: TextField(
                  key: const Key('phone-auth-phone'),
                  controller: controller,
                  enabled: !data.loading,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.telephoneNumberNational],
                  onChanged: onChanged,
                  onSubmitted: (_) => onSubmitted?.call(),
                  style: OType.body.copyWith(color: c.text),
                  decoration: InputDecoration(
                    hintText: data.country.example,
                    errorText: null,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _CountryButton extends StatelessWidget {
  const _CountryButton({
    required this.country,
    required this.enabled,
    required this.onTap,
  });

  final V2PhoneCountry country;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final content = Container(
      constraints: const BoxConstraints(minHeight: OSpace.touch),
      padding: const EdgeInsets.symmetric(horizontal: OSpace.m),
      decoration: BoxDecoration(
        color: enabled ? c.surfaceAlt : c.surfaceRaised,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.inputBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            country.region,
            style: OType.overline.copyWith(color: c.textFaint),
          ),
          const SizedBox(width: 6),
          Text(
            country.dialCode,
            style: OType.bodyStrong.copyWith(color: c.text),
          ),
          const SizedBox(width: 2),
          Icon(
            Icons.expand_more_rounded,
            size: 18,
            color: enabled ? c.textMuted : c.textFaint,
          ),
        ],
      ),
    );
    final label = 'Country code, ${country.name}, ${country.dialCode}';
    if (enabled) {
      return OPressable(
        key: const Key('phone-auth-country'),
        onTap: onTap,
        semanticLabel: label,
        child: ExcludeSemantics(child: content),
      );
    }
    return Semantics(
      key: const Key('phone-auth-country'),
      label: label,
      button: true,
      enabled: false,
      child: ExcludeSemantics(child: content),
    );
  }
}

class _CodeSubtitle extends StatelessWidget {
  const _CodeSubtitle({required this.number, required this.onChangeNumber});

  final String number;
  final VoidCallback? onChangeNumber;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: OSpace.xs,
      children: [
        Text(
          'We sent a 6-digit code to $number.',
          style: OType.bodySm.copyWith(color: c.textMuted),
        ),
        OButton(
          key: const Key('phone-auth-change'),
          label: 'Change',
          variant: OButtonVariant.ghost,
          onPressed: onChangeNumber,
        ),
      ],
    );
  }
}

class _CodeFields extends StatelessWidget {
  const _CodeFields({
    required this.data,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
  });

  final V2PhoneAuthData data;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;

  static const int _length = 6;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final slotHeight = (scaler.scale(24) * 1.4 + 24).clamp(56.0, 132.0);
    final code = controller.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Verification code',
          style: OType.label.copyWith(color: c.textMuted),
        ),
        const SizedBox(height: OSpace.s),
        Semantics(
          key: const Key('phone-auth-code'),
          label: '6-digit verification code',
          value: code.isEmpty ? null : code,
          textField: true,
          enabled: !data.loading,
          onTap: data.loading ? null : focusNode.requestFocus,
          child: ExcludeSemantics(
            child: Stack(
              children: [
                Row(
                  children: [
                    for (var i = 0; i < _length; i++) ...[
                      if (i > 0) const SizedBox(width: OSpace.s),
                      Expanded(
                        child: _OtpSlot(
                          digit: i < code.length ? code[i] : '',
                          height: slotHeight,
                          active: !data.loading && i == code.length,
                        ),
                      ),
                    ],
                  ],
                ),
                Positioned.fill(
                  child: TextField(
                    key: const Key('phone-auth-code-field'),
                    controller: controller,
                    focusNode: focusNode,
                    enabled: !data.loading,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    maxLength: _length,
                    showCursor: false,
                    enableInteractiveSelection: false,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(_length),
                    ],
                    onChanged: onChanged,
                    onSubmitted: (_) => onSubmitted(),
                    style: const TextStyle(
                      color: Colors.transparent,
                      fontSize: 1,
                      height: 1,
                    ),
                    cursorColor: Colors.transparent,
                    decoration: const InputDecoration(
                      counterText: '',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: OSpace.s),
        Text(
          'Enter all $_length digits',
          style: OType.caption.copyWith(color: c.textFaint),
        ),
      ],
    );
  }
}

class _OtpSlot extends StatelessWidget {
  const _OtpSlot({
    required this.digit,
    required this.height,
    required this.active,
  });

  final String digit;
  final double height;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return AnimatedContainer(
      duration: OMotion.fast,
      curve: OMotion.standard,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: digit.isEmpty ? c.surfaceAlt : c.surface,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(
          color: active ? c.accentFill : c.inputBorder,
          width: active ? 1.5 : 1,
        ),
      ),
      child: digit.isEmpty
          ? null
          : FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                digit,
                style: OType.h2.copyWith(
                  color: c.text,
                  fontFamily: 'JetBrainsMono',
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
    );
  }
}

class _ResendRow extends StatelessWidget {
  const _ResendRow({required this.data, required this.onResend});

  final V2PhoneAuthData data;
  final VoidCallback? onResend;

  static String _format(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return '$minutes:${rest.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    if (data.canResend) {
      return Align(
        alignment: Alignment.centerLeft,
        child: OButton(
          key: const Key('phone-auth-resend'),
          label: 'Resend code',
          icon: Icons.refresh_rounded,
          variant: OButtonVariant.ghost,
          onPressed: onResend,
        ),
      );
    }
    return Row(
      children: [
        Icon(Icons.timer_outlined, size: 16, color: c.textFaint),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Text(
            data.resendSeconds > 0
                ? 'Resend code in ${_format(data.resendSeconds)}'
                : 'One moment…',
            key: const Key('phone-auth-resend-timer'),
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ),
      ],
    );
  }
}

class _SheetError extends StatelessWidget {
  const _SheetError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const Key('phone-auth-error'),
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

class _TermsNote extends StatelessWidget {
  const _TermsNote({this.onTerms, this.onPrivacy});

  final VoidCallback? onTerms;
  final VoidCallback? onPrivacy;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final base = OType.caption.copyWith(color: c.textMuted);
    return Wrap(
      key: const Key('phone-auth-terms'),
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('By continuing, you agree to our ', style: base),
        _InlineLink(label: 'Terms', onTap: onTerms),
        Text(' and ', style: base),
        _InlineLink(label: 'Privacy Policy', onTap: onPrivacy),
        Text('.', style: base),
      ],
    );
  }
}

/// Inline text link with a 48 dp tap target. The enclosing terms note owns the
/// spoken sentence, so each link is what a screen reader can activate.
class _InlineLink extends StatelessWidget {
  const _InlineLink({required this.label, this.onTap});

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

class _CountryPickerSheet extends StatefulWidget {
  const _CountryPickerSheet({required this.countries, required this.selected});

  final List<V2PhoneCountry> countries;
  final V2PhoneCountry selected;

  @override
  State<_CountryPickerSheet> createState() => _CountryPickerSheetState();
}

class _CountryPickerSheetState extends State<_CountryPickerSheet> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<V2PhoneCountry> get _matches {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return widget.countries;
    return widget.countries
        .where(
          (country) =>
              country.name.toLowerCase().contains(query) ||
              country.region.toLowerCase().contains(query) ||
              country.dialCode.contains(query),
        )
        .toList(growable: false);
  }

  void _clearSearch() {
    _search.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final matches = _matches;
    final height = (MediaQuery.sizeOf(context).height * 0.6).clamp(
      280.0,
      520.0,
    );
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              OSpace.l,
              OSpace.s,
              OSpace.l,
              OSpace.s,
            ),
            child: TextField(
              key: const Key('phone-auth-country-search'),
              controller: _search,
              autofocus: false,
              textInputAction: TextInputAction.search,
              onChanged: (value) => setState(() => _query = value),
              style: OType.bodySm.copyWith(color: c.text),
              decoration: InputDecoration(
                hintText: 'Search country or code',
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: 20,
                  color: c.textFaint,
                ),
                suffixIcon: _query.isEmpty
                    ? null
                    : OIconButton(
                        icon: Icons.close_rounded,
                        semanticLabel: 'Clear search',
                        onPressed: _clearSearch,
                      ),
              ),
            ),
          ),
          if (matches.isEmpty)
            Expanded(
              child: OEmptyState(
                compact: true,
                icon: Icons.public_off_rounded,
                title: 'No countries found',
                message:
                    'Nothing matches "${_query.trim()}". Try a country or '
                    'code.',
                action: OButton(
                  label: 'Clear search',
                  variant: OButtonVariant.secondary,
                  onPressed: _clearSearch,
                ),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: OSpace.l),
                itemCount: matches.length,
                itemBuilder: (context, index) {
                  final country = matches[index];
                  final isSelected =
                      country.region == widget.selected.region &&
                      country.dialCode == widget.selected.dialCode;
                  return _CountryRow(
                    country: country,
                    selected: isSelected,
                    onTap: () => Navigator.of(context).pop(country),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _CountryRow extends StatelessWidget {
  const _CountryRow({
    required this.country,
    required this.selected,
    required this.onTap,
  });

  final V2PhoneCountry country;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OPressable(
      onTap: onTap,
      semanticLabel:
          '${country.name}, ${country.dialCode}'
          '${selected ? ', selected' : ''}',
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: OSpace.listRow),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: OSpace.l,
              vertical: OSpace.s,
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? c.accentSoft : c.surfaceAlt,
                    borderRadius: BorderRadius.circular(ORadius.m),
                    border: Border.all(
                      color: selected ? c.accentFill : c.hairline,
                    ),
                  ),
                  child: Text(
                    country.region,
                    style: OType.overline.copyWith(
                      color: selected ? c.accent : c.textMuted,
                    ),
                  ),
                ),
                const SizedBox(width: OSpace.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        country.name,
                        style: OType.body.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        country.dialCode,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle_rounded, size: 20, color: c.accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
