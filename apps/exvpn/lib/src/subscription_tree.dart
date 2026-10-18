import 'package:flutter/material.dart';

/// Compact subscription nesting with one straight rail and short branches.
///
/// Children keep their natural heights, including wrapped labels. The gutter
/// follows [Directionality] and never participates in input or semantics.
class SubscriptionTree extends StatelessWidget {
  const SubscriptionTree({
    super.key,
    required this.children,
    this.indent = 24,
    this.railOffset = 15,
  }) : assert(indent >= 3),
       assert(railOffset >= 0 && railOffset <= indent - 3);

  final List<Widget> children;
  final double indent;
  final double railOffset;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();

    final direction = Directionality.of(context);
    final color = Theme.of(context).colorScheme.onSurfaceVariant
        .withValues(alpha: .22);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < children.length; index++)
          Stack(
            fit: StackFit.passthrough,
            children: [
              Padding(
                padding: EdgeInsetsDirectional.only(start: indent),
                child: children[index],
              ),
              PositionedDirectional(
                start: 0,
                top: 0,
                bottom: 0,
                width: indent,
                child: ExcludeSemantics(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _BranchPainter(
                        color: color,
                        direction: direction,
                        railOffset: railOffset,
                        last: index == children.length - 1,
                      ),
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

class _BranchPainter extends CustomPainter {
  const _BranchPainter({
    required this.color,
    required this.direction,
    required this.railOffset,
    required this.last,
  });

  final Color color;
  final TextDirection direction;
  final double railOffset;
  final bool last;

  @override
  void paint(Canvas canvas, Size size) {
    final mirrored = direction == TextDirection.rtl;
    final rail = mirrored ? size.width - railOffset : railOffset;
    final branchEnd = mirrored ? 3.0 : size.width - 3;
    final center = size.height / 2;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.butt;
    canvas
      ..drawLine(
        Offset(rail, 0),
        Offset(rail, last ? center : size.height),
        paint,
      )
      ..drawLine(Offset(rail, center), Offset(branchEnd, center), paint);
  }

  @override
  bool shouldRepaint(_BranchPainter oldDelegate) =>
      color != oldDelegate.color ||
      direction != oldDelegate.direction ||
      railOffset != oldDelegate.railOffset ||
      last != oldDelegate.last;
}
