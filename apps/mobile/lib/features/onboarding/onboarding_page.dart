import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:suskii_design/suskii_design.dart';
import 'package:suskii_l10n/suskii_l10n.dart';

import '../../app/router.dart';

/// Three-slide intro pager. Skip/continue lands on the auth route.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final PageController _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _finish() => context.go(AppRoutes.auth);

  void _next() {
    if (_page >= 2) {
      _finish();
      return;
    }
    _controller.nextPage(duration: SMotion.normal, curve: SMotion.standard);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final slides = <(IconData, String, String)>[
      (Icons.format_list_bulleted, l10n.onboardingTitle1, l10n.onboardingBody1),
      (Icons.payments_outlined, l10n.onboardingTitle2, l10n.onboardingBody2),
      (Icons.location_on_outlined, l10n.onboardingTitle3, l10n.onboardingBody3),
    ];
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _finish,
                child: Text(l10n.onboardingSkip),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: slides.length,
                onPageChanged: (int index) => setState(() => _page = index),
                itemBuilder: (BuildContext context, int index) {
                  final (icon, title, body) = slides[index];
                  return Padding(
                    padding: const EdgeInsets.all(SSpacing.xl),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Icon(icon, size: 96, color: theme.colorScheme.primary),
                        const SizedBox(height: SSpacing.xl),
                        Text(
                          title,
                          style: theme.textTheme.headlineSmall,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: SSpacing.md),
                        Text(
                          body,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(SSpacing.xl),
              child: Column(
                children: <Widget>[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List<Widget>.generate(
                      slides.length,
                      (int index) => AnimatedContainer(
                        duration: SMotion.fast,
                        margin: const EdgeInsets.symmetric(
                          horizontal: SSpacing.xs,
                        ),
                        width: index == _page ? 24 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: index == _page
                              ? theme.colorScheme.primary
                              : theme.colorScheme.surfaceContainerHighest,
                          borderRadius: SRadius.borderMd,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: SSpacing.lg),
                  SButton(label: l10n.actionContinue, onPressed: _next),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
