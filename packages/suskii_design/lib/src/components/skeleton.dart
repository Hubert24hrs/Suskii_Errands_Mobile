import 'package:flutter/material.dart';

import '../tokens/radius.dart';
import '../tokens/spacing.dart';

/// Skeleton placeholder box with a gentle pulse. Compose for loaders.
class SSkeleton extends StatefulWidget {
  const SSkeleton({
    super.key,
    this.width,
    this.height = 16,
    this.circle = false,
  });

  final double? width;
  final double height;
  final bool circle;

  @override
  State<SSkeleton> createState() => _SSkeletonState();
}

class _SSkeletonState extends State<SSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    return FadeTransition(
      opacity: Tween<double>(begin: 0.55, end: 1).animate(_controller),
      child: Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: base,
          shape: widget.circle ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: widget.circle ? null : SRadius.borderSm,
        ),
      ),
    );
  }
}

/// Standard list-loading skeleton: an avatar row plus two text lines.
class SSkeletonListTile extends StatelessWidget {
  const SSkeletonListTile({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(
        horizontal: SSpacing.lg,
        vertical: SSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          SSkeleton(width: 48, height: 48, circle: true),
          SizedBox(width: SSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SSkeleton(height: 14, width: 160),
                SizedBox(height: SSpacing.sm),
                SSkeleton(height: 12, width: 110),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
