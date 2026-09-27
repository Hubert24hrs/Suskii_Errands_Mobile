import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/motion.dart';
import '../tokens/spacing.dart';
import 'motion.dart';

/// 5-star rating input. Read-only when [onChanged] is null.
class SRatingInput extends StatelessWidget {
  const SRatingInput({
    required this.value,
    super.key,
    this.onChanged,
    this.size = 32,
    this.semanticLabel,
  });

  /// 0–5.
  final int value;
  final ValueChanged<int>? onChanged;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: semanticLabel,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List<Widget>.generate(5, (int index) {
          final star = index + 1;
          final selected = star <= value;
          return SizedBox(
            width: size.clamp(SSpacing.minTouchTarget, 64),
            height: SSpacing.minTouchTarget,
            child: IconButton(
              padding: EdgeInsets.zero,
              tooltip: '$star/5',
              onPressed: onChanged == null
                  ? null
                  : () {
                      SHaptics.selection();
                      onChanged!(star);
                    },
              icon: AnimatedScale(
                scale: selected ? 1.12 : 1,
                duration: SMotion.of(context, SMotion.fast),
                curve: SMotion.spring,
                child: Icon(
                  selected ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: size,
                  color: selected ? context.sColors.warning : scheme.outline,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
