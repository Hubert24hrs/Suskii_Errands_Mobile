import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/error_l10n.dart';
import '../../app/providers.dart';

enum _AuthMethod { phone, email }

/// Phone/email + OTP sign-in. On success the router redirect takes over
/// (MFA prompt placeholder first) — this page never navigates itself.
class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key});

  @override
  ConsumerState<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends ConsumerState<AuthPage> {
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();

  _AuthMethod _method = _AuthMethod.phone;
  bool _codeSent = false;
  bool _busy = false;
  Object? _error;

  @override
  void dispose() {
    _phoneController.dispose();
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  TextEditingController get _identityController =>
      _method == _AuthMethod.phone ? _phoneController : _emailController;

  Future<void> _sendCode() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = ref.read(authRepositoryProvider);
      final identity = _identityController.text.trim();
      if (_method == _AuthMethod.phone) {
        await auth.requestPhoneOtp(identity);
      } else {
        await auth.requestEmailOtp(identity);
      }
      if (mounted) setState(() => _codeSent = true);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = ref.read(authRepositoryProvider);
      final identity = _identityController.text.trim();
      if (_method == _AuthMethod.phone) {
        await auth.verifyPhoneOtp(identity, _codeController.text);
      } else {
        await auth.verifyEmailOtp(identity, _codeController.text);
      }
      // Signed in — the router redirect moves us to the MFA prompt, then home.
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _selectMethod(_AuthMethod method) {
    setState(() {
      _method = method;
      _codeSent = false;
      _error = null;
      _codeController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final error = _error;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(SSpacing.xl),
          children: <Widget>[
            const SizedBox(height: SSpacing.xxl),
            Text(l10n.authTitle, style: theme.textTheme.headlineMedium),
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
              onSelectionChanged: (Set<_AuthMethod> selection) =>
                  _selectMethod(selection.first),
            ),
            const SizedBox(height: SSpacing.lg),
            if (_method == _AuthMethod.phone)
              STextField(
                label: l10n.authPhoneLabel,
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                textInputAction: _codeSent
                    ? TextInputAction.done
                    : TextInputAction.next,
                onChanged: (_) => setState(() => _error = null),
              )
            else
              STextField(
                label: l10n.authEmailLabel,
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                textInputAction: _codeSent
                    ? TextInputAction.done
                    : TextInputAction.next,
                onChanged: (_) => setState(() => _error = null),
              ),
            if (_codeSent) ...<Widget>[
              const SizedBox(height: SSpacing.lg),
              STextField(
                label: l10n.authOtpLabel,
                controller: _codeController,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() => _error = null),
              ),
              const SizedBox(height: SSpacing.sm),
              Text(
                l10n.authDemoHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (error != null) ...<Widget>[
              const SizedBox(height: SSpacing.md),
              Text(
                localizedError(l10n, error),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: SSpacing.xl),
            if (!_codeSent)
              SButton(
                label: l10n.authSendCode,
                loading: _busy,
                onPressed: _identityController.text.trim().isEmpty
                    ? null
                    : _sendCode,
              )
            else
              SButton(
                label: l10n.authVerify,
                loading: _busy,
                onPressed: _codeController.text.length == 6 ? _verify : null,
              ),
            const SizedBox(height: SSpacing.xxl),
            SButton(
              label: l10n.authContinueGoogle,
              variant: SButtonVariant.ghost,
              icon: Icons.g_mobiledata,
            ),
            const SizedBox(height: SSpacing.sm),
            SButton(
              label: l10n.authContinueApple,
              variant: SButtonVariant.ghost,
              icon: Icons.apple,
            ),
            const SizedBox(height: SSpacing.sm),
            Text(
              l10n.authComingSoon,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
