import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;

import 'l10n.dart';
import 'sheet_widgets.dart';

/// The vehicle's icon in an expressive cookie shape, leading both toolbars.
class _VehicleBadge extends StatelessWidget {
  const _VehicleBadge(this.mode);
  final String mode;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return M3EShapeContainer(
      kind: M3EShapeKind.cookie7Sided,
      width: 44,
      height: 44,
      color: cs.primary,
      child: Center(child: Icon(modeIcon(mode), size: 24, color: cs.onPrimary)),
    );
  }
}

/// Floating toolbar at the top centre while journeys start on a vehicle
/// you ride: "You're on the 341", "→ Ponte Mammolo" below, and a red ✕ to
/// leave that mode.
class OnBoardBar extends StatelessWidget {
  const OnBoardBar({super.key, required this.line, required this.mode, required this.headsign, required this.onLeave});
  final String line;
  final String mode;
  final String headsign;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final cs = Theme.of(context).colorScheme;
    final fg = cs.onPrimaryContainer;
    return M3EToolbar.floating(
      alignment: Alignment.topCenter,
      colorStyle: M3EToolbarColorStyle.vibrant,
      semanticLabel: '${l.onBoardYouAreOn(line)} → ${titleCase(headsign)}',
      leading: _VehicleBadge(mode),
      title: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.onBoardYouAreOn(line),
            maxLines: 1, overflow: TextOverflow.ellipsis, style: emphasized(context).titleLarge.copyWith(color: fg, height: 1.1)),
        if (headsign.isNotEmpty)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.arrow_forward_rounded, size: 14, color: fg),
            const SizedBox(width: 4),
            Flexible(
              child: Text(titleCase(headsign),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(color: fg)),
            ),
          ]),
      ]),
      // Red and round: clearly "leave this mode".
      trailing: IconButton.filled(
        icon: const Icon(Icons.close_rounded),
        tooltip: l.leaveBoard,
        style: IconButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError),
        onPressed: onLeave,
      ),
    );
  }
}

/// Same place, when you seem to ride a bus: "Are you on the 341?" No / Yes.
class BoardQuestionBar extends StatelessWidget {
  const BoardQuestionBar({super.key, required this.line, required this.mode, required this.onYes, required this.onNo});
  final String line;
  final String mode;
  final VoidCallback onYes;
  final VoidCallback onNo;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fg = Theme.of(context).colorScheme.onPrimaryContainer;
    return M3EToolbar.floating(
      alignment: Alignment.topCenter,
      colorStyle: M3EToolbarColorStyle.vibrant,
      leading: _VehicleBadge(mode),
      title: Text(l.onBoardQuestion(line),
          maxLines: 1, overflow: TextOverflow.ellipsis, style: emphasized(context).titleLarge.copyWith(color: fg)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        M3EButton(style: M3EButtonStyle.text, label: Text(l.no), onPressed: onNo),
        const SizedBox(width: 4),
        M3EButton(label: Text(l.yes), onPressed: onYes),
      ]),
    );
  }
}
