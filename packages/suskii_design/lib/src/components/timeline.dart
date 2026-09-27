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
        final next = isLast ? null : steps[index + 1].state;
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Column(
                children: <Widget>[
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: step.state == STimelineStepState.upcoming
                          ? Colors.transparent
                          : color.withValues(alpha: 0.16),
                      border: Border.all(color: color, width: 2),
                    ),
                    child: step.state == STimelineStepState.done
                        ? Icon(Icons.check_rounded, size: 14, color: color)
                        : step.state == STimelineStepState.current
                        ? Center(
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                              ),
                            ),
                          )
                        : null,
                  ),
                  if (!isLast)
                    Expanded(
                      child: Container(
                        width: 2,
                        margin: const EdgeInsets.symmetric(
                          vertical: SSpacing.xs,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(1),
                          gradient: next == STimelineStepState.upcoming
                              ? null
                              : LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: <Color>[
                                    scheme.primary,
                                    scheme.secondary,
                                  ],
                                ),
                          color: next == STimelineStepState.upcoming
                              ? scheme.outlineVariant
                              : null,
                        ),
                      ),
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
