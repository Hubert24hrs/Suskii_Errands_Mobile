import 'package:flutter/material.dart';

import '../tokens/spacing.dart';

enum STimelineStepState { done, current, upcoming }

class SStatusStep {
  const SStatusStep({required this.label, required this.state, this.timestamp});

  final String label;
  final STimelineStepState state;
  final DateTime? timestamp;
}

/// Vertical status timeline for job tracking and dispute timelines.
class SStatusTimeline extends StatelessWidget {
  const SStatusTimeline({required this.steps, super.key});

  final List<SStatusStep> steps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      children: List<Widget>.generate(steps.length, (int index) {
        final step = steps[index];
        final isLast = index == steps.length - 1;
        final color = switch (step.state) {
          STimelineStepState.done => scheme.primary,
          STimelineStepState.current => scheme.secondary,
          STimelineStepState.upcoming => scheme.outline,
        };
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Column(
                children: <Widget>[
                  Icon(
                    step.state == STimelineStepState.done
                        ? Icons.check_circle
                        : step.state == STimelineStepState.current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 20,
                    color: color,
                  ),
                  if (!isLast)
                    Expanded(
                      child: VerticalDivider(color: scheme.outlineVariant),
                    ),
                ],
              ),
              const SizedBox(width: SSpacing.md),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: SSpacing.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        step.label,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: step.state == STimelineStepState.upcoming
                              ? scheme.onSurfaceVariant
                              : scheme.onSurface,
                        ),
                      ),
                      if (step.timestamp != null)
                        Text(
                          TimeOfDay.fromDateTime(step.timestamp!)
                              .format(context),
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}
