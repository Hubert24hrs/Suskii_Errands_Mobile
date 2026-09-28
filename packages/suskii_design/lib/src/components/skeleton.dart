import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/radius.dart';
import '../tokens/spacing.dart';

/// Skeleton placeholder with a shimmer sweep. Compose for loaders. Under
/// reduced motion it is a still block (a sweep that never ends is exactly
/// what that setting asks to stop).
class SSkeleton extends StatefulWidget {
  const SSkeleton({
    super.key,
    this.width,
    this.height = 16,
    this.circle = false,
    this.borderRadius = SRadius.borderSm,
  });

  final double? width;
  final double height;
  final bool circle;
  final BorderRadius borderRadius;

  @override
  State<SSkeleton> createState() => _SSkeletonState();
}

class _SSkeletonState extends State<SSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.sColors;
    final shape = BoxDecoration(
      color: palette.shimmerBase,
      shape: widget.circle ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: widget.circle ? null : widget.borderRadius,
    );
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          final t = _controller.value;
          return Container(
            width: widget.width,
            height: widget.height,
            decoration: shape.copyWith(
              gradient: LinearGradient(
                begin: Alignment(-1.5 + 3 * t, 0),
                end: Alignment(-0.5 + 3 * t, 0),
                colors: <Color>[
                  palette.shimmerBase,
                  palette.shimmerHighlight,
                  palette.shimmerBase,
                ],
              ),
            ),
          );
        },
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

/// A card-shaped skeleton for hero and offer cards.
class SSkeletonCard extends StatelessWidget {
  const SSkeletonCard({super.key, this.height = 140});

  final double height;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: SSpacing.xs),
    child: SSkeleton(height: height, borderRadius: SRadius.borderLg),
  );
}
