import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;
import 'l10n.dart';

/// Horizontal swipe between variants of one leg (e.g. 88 / 3 / 90).
///
/// The card follows the finger a little, then slides out/in in the swipe
/// direction. Below it, arrows at the edges and centred page dots show there
/// is something to swipe to.
class SwipeSlot extends StatefulWidget {
  const SwipeSlot({
    super.key,
    required this.index,
    required this.count,
    required this.labels,
    required this.onChanged,
    required this.child,
  });

  final int index;
  final int count;

  /// One short label per variant ("88 08:04"), shown as hints.
  final List<String> labels;
  final ValueChanged<int> onChanged;
  final Widget child;

  @override
  State<SwipeSlot> createState() => _SwipeSlotState();
}

class _SwipeSlotState extends State<SwipeSlot> {
  double _drag = 0;
  int _direction = 1; // +1: came from the right (swiped left)

  void _go(int delta) {
    final next = widget.index + delta;
    if (next < 0 || next >= widget.count) {
      HapticFeedback.heavyImpact(); // edge
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _direction = delta);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasPrev = widget.index > 0, hasNext = widget.index < widget.count - 1;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: (d) => setState(() => _drag += d.delta.dx),
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        final dx = _drag;
        setState(() => _drag = 0);
        if (dx < -56 || v < -400) {
          _go(1);
        } else if (dx > 56 || v > 400) {
          _go(-1);
        }
      },
      onHorizontalDragCancel: () => setState(() => _drag = 0),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        AnimatedSlide(
          offset: Offset(_drag / 1200, 0),
          duration: _drag == 0 ? const Duration(milliseconds: 250) : Duration.zero,
          curve: Curves.easeOutBack,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
            transitionBuilder: (child, anim) {
              final incoming = child.key == ValueKey(widget.index);
              final from = Offset(incoming ? 0.35 * _direction : -0.35 * _direction, 0);
              return FadeTransition(
                opacity: anim,
                child: SlideTransition(position: Tween(begin: from, end: Offset.zero).animate(anim), child: child),
              );
            },
            child: KeyedSubtree(key: ValueKey(widget.index), child: widget.child),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          // Arrows at the edges, page dots centred: the options are found by
          // swiping; their names live in the arrows' tooltips / semantics.
          child: Row(children: [
            _ArrowButton(
              icon: Icons.chevron_left_rounded,
              tooltip: hasPrev ? context.l10n.swipePrevious(widget.labels[widget.index - 1]) : null,
              enabled: hasPrev,
              onTap: () => _go(-1),
            ),
            Expanded(
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 0; i < widget.count; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutBack,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    width: i == widget.index ? 16 : 6,
                    height: 6,
                    decoration: ShapeDecoration(
                      color: i == widget.index ? cs.primary : cs.outlineVariant,
                      shape: const StadiumBorder(),
                    ),
                  ),
              ]),
            ),
            _ArrowButton(
              icon: Icons.chevron_right_rounded,
              tooltip: hasNext ? context.l10n.swipeNext(widget.labels[widget.index + 1]) : null,
              enabled: hasNext,
              onTap: () => _go(1),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _ArrowButton extends StatelessWidget {
  const _ArrowButton({required this.icon, required this.enabled, required this.onTap, this.tooltip});
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => M3EIconButton(
        icon: Icon(icon),
        tooltip: tooltip,
        size: M3EIconButtonSize.xs,
        variant: M3EIconButtonVariant.tonal,
        onPressed: enabled ? onTap : null,
      );
}
