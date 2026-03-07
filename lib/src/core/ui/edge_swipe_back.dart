import 'package:flutter/material.dart';

/// Adds an iOS-style edge swipe-back gesture for routes that can pop.
class EdgeSwipeBack extends StatefulWidget {
  const EdgeSwipeBack({
    super.key,
    required this.child,
    this.enabled = true,
    this.edgeWidth = 24,
    this.popDistance = 72,
    this.popVelocity = 650,
  });

  final Widget child;
  final bool enabled;
  final double edgeWidth;
  final double popDistance;
  final double popVelocity;

  @override
  State<EdgeSwipeBack> createState() => _EdgeSwipeBackState();
}

class _EdgeSwipeBackState extends State<EdgeSwipeBack> {
  double _dragDistance = 0;

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    if (!widget.enabled || !canPop) {
      return widget.child;
    }

    final isLtr = Directionality.of(context) == TextDirection.ltr;
    final edge = PositionedDirectional(
      start: 0,
      top: 0,
      bottom: 0,
      width: widget.edgeWidth,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) {
          _dragDistance = 0;
        },
        onHorizontalDragUpdate: (details) {
          final delta = details.primaryDelta ?? 0;
          _dragDistance += isLtr ? delta : -delta;
        },
        onHorizontalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          final directionalVelocity = isLtr ? velocity : -velocity;
          if (_dragDistance >= widget.popDistance ||
              directionalVelocity >= widget.popVelocity) {
            Navigator.of(context).maybePop();
          }
          _dragDistance = 0;
        },
        onHorizontalDragCancel: () {
          _dragDistance = 0;
        },
      ),
    );

    return Stack(children: [widget.child, edge]);
  }
}
