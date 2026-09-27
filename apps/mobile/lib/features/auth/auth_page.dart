import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/external_links.dart';
import '../../app/providers.dart';

enum _AuthMethod { phone, email }

/// International dialling codes of the launch countries (ITU-T E.164).
const Map<String, String> _dialCodes = <String, String>{
  'NG': '234',
  'KE': '254',
  'GH': '233',
  'ZA': '27',
  'UG': '256',
};

/// Normalises what a person types into E.164: a leading `+` is taken as
/// international, a leading trunk `0` is replaced by the country's code, and
/// anything else is assumed to be a national number. Null when it cannot be
/// a phone number.
String? normalizePhone(String raw, String countryCode) {
  final digits = raw.replaceAll(RegExp(r'[^0-9+]'), '');
  final dial = _dialCodes[countryCode] ?? '';
  String candidate;
  if (digits.startsWith('+')) {
    candidate = digits;
  } else if (digits.startsWith('00')) {
    candidate = '+${digits.substring(2)}';
  } else if (digits.startsWith('0')) {
    candidate = '+$dial${digits.substring(1)}';
  } else if (dial.isNotEmpty && digits.startsWith(dial)) {
    candidate = '+$digits';
  } else {
    candidate = '+$dial$digits';
  }
  return RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(candidate) ? candidate : null;
}

/// Phone/email + OTP sign-in. On success the router redirect takes over —
/// this page never navigates itself.
class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key});

  @override
  ConsumerState<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends ConsumerState<AuthPage> {
  static const Duration _resendCooldown = Duration(seconds: 30);

  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();

  _AuthMethod _method = _AuthMethod.phone;
  bool _codeSent = false;
  bool _busy = false;
  Object? _error;
  bool _identityInvalid = false;

  /// The identity the code was sent to — verified against, not re-read from
  /// the field, so editing the field after sending cannot desynchronise.
  String? _sentTo;
  Timer? _cooldownTimer;
  int _cooldownLeft = 0;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _phoneController.dispose();
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  String get _country => ref.read(selectedCountryProvider) ?? 'NG';

  /// The identity to send a code to, or null when the input is not valid.
  String? _identity() {
    if (_method == _AuthMethod.phone) {
      return normalizePhone(_phoneController.text, _country);
    }
    final email = _emailController.text.trim();
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email) ? email : null;
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldownLeft = _resendCooldown.inSeconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _cooldownLeft--);
      if (_cooldownLeft <= 0) timer.cancel();
    });
  }

  Future<void> _sendCode() async {
    final identity = _identity();
    if (identity == null) {
      setState(() => _identityInvalid = true);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _identityInvalid = false;
    });
    try {
      final auth = ref.read(authRepositoryProvider);
      final language = Localizations.localeOf(context).languageCode;
      if (_method == _AuthMethod.phone) {
        await auth.requestPhoneOtp(
          identity,
          countryCode: _country,
          language: language,
        );
      } else {
        await auth.requestEmailOtp(
          identity,
          countryCode: _country,
          language: language,
        );
      }
      if (mounted) {
        setState(() {
          _codeSent = true;
          _sentTo = identity;
        });
        _startCooldown();
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    final identity = _sentTo;
    if (identity == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = ref.read(authRepositoryProvider);
      if (_method == _AuthMethod.phone) {
        await auth.verifyPhoneOtp(identity, _codeController.text);
      } else {
        await auth.verifyEmailOtp(identity, _codeController.text);
      }
      // Signed in — the router redirect moves us on.
      unawaited(HapticFeedback.mediumImpact());
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _changeIdentity() {
    _cooldownTimer?.cancel();
    setState(() {
      _codeSent = false;
      _sentTo = null;
      _error = null;
      _cooldownLeft = 0;
      _codeController.clear();
    });
  }

  void _selectMethod(_AuthMethod method) {
    _changeIdentity();
    setState(() {
      _method = method;
      _identityInvalid = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final config = ref.watch(appConfigProvider);
    final error = _error;
    final dial = _dialCodes[ref.watch(selectedCountryProvider) ?? 'NG'];

    return Scaffold(
      body: SafeArea(
        child: AutofillGroup(
          child: ListView(
            padding: const EdgeInsets.all(SSpacing.xl),
            children: <Widget>[
              const SizedBox(height: SSpacing.xxl),
              Text(l10n.authTitle, style: theme.textTheme.headlineMedium),
              const SizedBox(height: SSpacing.sm),
              Text(
                l10n.authSubtitle,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: SSpacing.xl),
              SegmentedButton<_AuthMethod>(
                segments: <ButtonSegment<_AuthMethod>>[
                  ButtonSegment<_AuthMethod>(
                    value: _AuthMethod.phone,
                    label: Text(l10n.authMethodPhone),
                    icon: const Icon(Icons.phone_outlined),
                  ),
                  ButtonSegment<_AuthMethod>(
                    value: _AuthMethod.email,
                    label: Text(l10n.authMethodEmail),
                    icon: const Icon(Icons.mail_outline),
                  ),
                ],
                selected: <_AuthMethod>{_method},
                onSelectionChanged: _busy
                    ? null
                    : (Set<_AuthMethod> selection) =>
                          _selectMethod(selection.first),
              ),
              const SizedBox(height: SSpacing.lg),
              TextField(
                key: const ValueKey<String>('auth.identity'),
                controller: _method == _AuthMethod.phone
                    ? _phoneController
                    : _emailController,
                enabled: !_codeSent,
                keyboardType: _method == _AuthMethod.phone
                    ? TextInputType.phone
                    : TextInputType.emailAddress,
                autofillHints: <String>[
                  if (_method == _AuthMethod.phone)
                    AutofillHints.telephoneNumber
                  else
                    AutofillHints.email,
                ],
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {
                  _error = null;
                  _identityInvalid = false;
                }),
                onSubmitted: (_) => _busy ? null : _sendCode(),
                decoration: InputDecoration(
                  labelText: _method == _AuthMethod.phone
                      ? l10n.authPhoneLabel
                      : l10n.authEmailLabel,
                  prefixText: _method == _AuthMethod.phone && dial != null
                      ? '+$dial '
                      : null,
                  errorText: _identityInvalid
                      ? (_method == _AuthMethod.phone
                            ? l10n.authPhoneInvalid
                            : l10n.authEmailInvalid)
                      : null,
                  suffixIcon: _codeSent
                      ? IconButton(
                          tooltip: l10n.authChangeIdentity,
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: _busy ? null : _changeIdentity,
                        )
                      : null,
                ),
              ),
              if (_codeSent) ...<Widget>[
                const SizedBox(height: SSpacing.lg),
                TextField(
                  key: const ValueKey<String>('auth.code'),
                  controller: _codeController,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  autofillHints: const <String>[AutofillHints.oneTimeCode],
                  maxLength: 6,
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  style: theme.textTheme.headlineSmall?.copyWith(
                    letterSpacing: 8,
                  ),
                  onChanged: (String value) {
                    setState(() => _error = null);
                    if (value.length == 6 && !_busy) unawaited(_verify());
                  },
                  decoration: InputDecoration(
                    labelText: l10n.authOtpLabel,
                    helperText: l10n.authCodeSentTo(_sentTo ?? ''),
                    counterText: '',
                  ),
                ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    onPressed: _busy || _cooldownLeft > 0 ? null : _sendCode,
                    child: Text(
                      _cooldownLeft > 0
                          ? l10n.authResendIn(_cooldownLeft)
                          : l10n.authResendCode,
                    ),
                  ),
                ),
                if (config.usesMockBackend)
                  Text(
                    l10n.authDemoHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
              if (error != null) ...<Widget>[
                const SizedBox(height: SSpacing.md),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    localizedError(l10n, error),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: SSpacing.xl),
              if (!_codeSent)
                SButton(
                  key: const ValueKey<String>('auth.send'),
                  label: l10n.authSendCode,
                  loading: _busy,
                  onPressed: _busy ? null : _sendCode,
                )
              else
                SButton(
                  key: const ValueKey<String>('auth.verify'),
                  label: l10n.authVerify,
                  loading: _busy,
                  onPressed: _codeController.text.length == 6 && !_busy
                      ? _verify
                      : null,
                ),
              const SizedBox(height: SSpacing.xl),
              _LegalNotice(
                privacyUrl: config.privacyPolicyUrl,
                termsUrl: config.termsUrl,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "By continuing you agree to the Terms and the Privacy Policy", with both
/// as links. Both stores require the privacy policy to be reachable in-app.
class _LegalNotice extends StatefulWidget {
  const _LegalNotice({required this.privacyUrl, required this.termsUrl});

  final String privacyUrl;
  final String termsUrl;

  @override
  State<_LegalNotice> createState() => _LegalNoticeState();
}

class _LegalNoticeState extends State<_LegalNotice> {
  late final TapGestureRecognizer _terms = TapGestureRecognizer()
    ..onTap = () => openExternalUrl(widget.termsUrl);
  late final TapGestureRecognizer _privacy = TapGestureRecognizer()
    ..onTap = () => openExternalUrl(widget.privacyUrl);

  @override
  void dispose() {
    _terms.dispose();
    _privacy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final base = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final link = base?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.w600,
      decoration: TextDecoration.underline,
    );
    return Text.rich(
      TextSpan(
        style: base,
        children: <InlineSpan>[
          TextSpan(text: '${l10n.authLegalPrefix} '),
          TextSpan(text: l10n.legalTerms, style: link, recognizer: _terms),
          TextSpan(text: ' ${l10n.authLegalAnd} '),
          TextSpan(text: l10n.legalPrivacy, style: link, recognizer: _privacy),
          const TextSpan(text: '.'),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}
