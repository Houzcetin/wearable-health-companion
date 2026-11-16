import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A horizontal track showing the usual range (a tinted band), the usual
/// value (a tick) and today's value (a dot). Decorative: callers describe the
/// same numbers in text, so the bar is excluded from semantics.
class UsualRangeBar extends StatelessWidget {
  const UsualRangeBar({
    super.key,
    required this.value,
    required this.usual,
    required this.low,
    required this.high,
    required this.color,
  });
  final double value, usual, low, high;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Stronger than the icon tint so the band reads against the grey track.
    final band = Color.alphaBlend(
      color.withValues(alpha: 0.3), scheme.surfaceContainerLowest);
    var lo = math.min(math.min(low, value), usual);
    var hi = math.max(math.max(high, value), usual);
    final spread = hi - lo;
    final pad = spread == 0 ? math.max(usual.abs() * 0.1, 1.0) : spread * 0.35;
    lo -= pad;
    hi += pad;
    double at(double v) => ((v - lo) / (hi - lo)).clamp(0.0, 1.0);

    return ExcludeSemantics(
      child: SizedBox(
        height: 16,
        child: LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0, right: 0, top: 4, height: 8,
                child: DecoratedBox(decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(4),
                )),
              ),
              Positioned(
                left: at(low) * width,
                width: math.max((at(high) - at(low)) * width, 4),
                top: 4, height: 8,
                child: DecoratedBox(decoration: BoxDecoration(
                  color: band,
                  borderRadius: BorderRadius.circular(4),
                )),
              ),
              Positioned(
                left: at(usual) * width - 1, top: 1, width: 2, height: 14,
                child: DecoratedBox(decoration: BoxDecoration(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(1),
                )),
              ),
              Positioned(
                left: at(value) * width - 7, top: 1, width: 14, height: 14,
                child: DecoratedBox(decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surfaceContainerLowest, width: 2),
                )),
              ),
            ],
          );
        }),
      ),
    );
  }
}
