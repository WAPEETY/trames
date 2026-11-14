import 'dart:ui' show lerpDouble;

import 'package:flutter/physics.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;

import 'sheet_widgets.dart' show emphasized;
import 'l10n.dart';

/// One container for origin + destination.
///
/// Collapsed it is a single "Where to?" pill. Expanded, the "From" row grows
/// in above the destination on an expressive spatial spring (damping 0.8,
/// stiffness 380), the corners relax from a pill to a card, and a swap button
/// fades in. Each row opens the M3E search view for its own field.
class RoutePicker extends StatefulWidget {
  const RoutePicker({
    super.key,
    required this.expanded,
    required this.fromSearch,
    required this.toSearch,
    required this.fromLabel,
    required this.toLabel,
    required this.fromIsMyLocation,
    required this.fromSuggestions,
    required this.toSuggestions,
    this.onSwap,
    this.onClear,
  });

  final bool expanded;
  final M3ESearchController fromSearch;
  final M3ESearchController toSearch;
  final String fromLabel;
  final String? toLabel;
  final bool fromIsMyLocation;
  final M3ESearchSuggestionsBuilder fromSuggestions;
  final M3ESearchSuggestionsBuilder toSuggestions;
  final VoidCallback? onSwap;
  final VoidCallback? onClear;

  @override
  State<RoutePicker> createState() => _RoutePickerState();
}

class _RoutePickerState extends State<RoutePicker> with SingleTickerProviderStateMixin {
  static final _spring = SpringDescription.withDampingRatio(mass: 1, stiffness: 380, ratio: 0.8);
  static const _rowHeight = 56.0;

  late final AnimationController _t = AnimationController.unbounded(vsync: this, value: widget.expanded ? 1 : 0);

  @override
  void didUpdateWidget(RoutePicker old) {
    super.didUpdateWidget(old);
    if (old.expanded != widget.expanded) {
      _t.animateWith(SpringSimulation(_spring, _t.value, widget.expanded ? 1 : 0, _t.velocity));
    }
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _t,
      builder: (context, _) {
        final t = _t.value; // may overshoot slightly: that's the spring
        final p = t.clamp(0.0, 1.0);
        // Pill (radius = half height) when collapsed, large card when expanded.
        final radius = lerpDouble(_rowHeight / 2, 24, p)!;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Material(
            color: cs.surfaceContainerHigh,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
            clipBehavior: Clip.antiAlias,
            child: Row(children: [
              Expanded(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  // "From" row grows in from zero height; slight overshoot allowed.
                  ClipRect(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      heightFactor: t.clamp(0.0, 1.08),
                      child: Opacity(
                        opacity: Curves.easeIn.transform(p),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          _anchor(
                            controller: widget.fromSearch,
                            suggestions: widget.fromSuggestions,
                            viewHint: context.l10n.startFrom,
                            icon: widget.fromIsMyLocation ? Icons.my_location_rounded : Icons.trip_origin_rounded,
                            iconColor: cs.primary,
                            text: widget.fromLabel,
                            hint: context.l10n.fromHint,
                          ),
                          Divider(height: 1, indent: 56, color: cs.outlineVariant),
                        ]),
                      ),
                    ),
                  ),
                  _anchor(
                    controller: widget.toSearch,
                    suggestions: widget.toSuggestions,
                    viewHint: context.l10n.searchPlaceHint,
                    // Search glyph while it is a plain search pill, a pin once it is a route field.
                    icon: p > 0.5 || widget.toLabel != null ? Icons.place_rounded : Icons.search_rounded,
                    iconColor: p > 0.5 || widget.toLabel != null ? cs.error : cs.onSurfaceVariant,
                    text: widget.toLabel,
                    hint: context.l10n.whereTo,
                    trailing: widget.toLabel != null
                        ? IconButton(
                            tooltip: context.l10n.clearDestination,
                            icon: const Icon(Icons.close_rounded),
                            onPressed: widget.onClear,
                          )
                        : null,
                  ),
                ]),
              ),
              // Swap button: only meaningful with both rows visible.
              SizedBox(
                width: 56 * p,
                child: p < 0.05
                    ? null
                    : Opacity(
                        opacity: p,
                        child: Transform.scale(
                          scale: 0.6 + 0.4 * p,
                          child: M3EIconButton(
                            icon: const Icon(Icons.swap_vert_rounded),
                            tooltip: context.l10n.swapOriginDestination,
                            variant: M3EIconButtonVariant.standard,
                            onPressed: widget.toLabel == null ? null : widget.onSwap,
                          ),
                        ),
                      ),
              ),
            ]),
          ),
        );
      },
    );
  }

  Widget _anchor({
    required M3ESearchController controller,
    required M3ESearchSuggestionsBuilder suggestions,
    required String viewHint,
    required IconData icon,
    required Color iconColor,
    required String? text,
    required String hint,
    Widget? trailing,
  }) {
    final cs = Theme.of(context).colorScheme;
    return M3ESearchAnchor(
      searchController: controller,
      viewHintText: viewHint,
      suggestionsBuilder: suggestions,
      builder: (context, c) => InkWell(
        onTap: c.openView,
        child: SizedBox(
          height: _rowHeight,
          child: Row(children: [
            const SizedBox(width: 16),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
              child: Icon(icon, key: ValueKey(icon), color: iconColor),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                text ?? hint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text == null
                    ? Theme.of(context).textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant)
                    : emphasized(context).bodyLarge.copyWith(color: cs.onSurface),
              ),
            ),
            if (trailing != null) trailing else const SizedBox(width: 16),
          ]),
        ),
      ),
    );
  }
}
