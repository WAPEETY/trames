import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;

import 'backend/backend.dart';
import 'l10n.dart';
import 'sheet_widgets.dart';

/// What the line view shows: one line, one of its trips (a direction) with
/// path and stops, plus every live bus of the line on the map.
class LineState {
  LineState(this.name, this.mode);
  final String name;
  final String mode;

  /// Trip shown (route + stops); one per direction, see [directions].
  String? tripId;
  TripInfo? trip;
  bool loading = true;
  String? error;

  /// GTFS direction id -> a trip id running that way (from live vehicles).
  Map<int, String> directions = {};

  /// Where each known trip can be found again if the planner doesn't know
  /// its id (another timetable version; see TripDetails.sameRun).
  Map<String, RunHint> runHints = {};
}

/// Header + stop list for the line view.
List<Widget> lineSlivers(
  BuildContext context,
  LineState s, {
  required Color color,
  /// Live buses of the line on the map; null where the city has no Tramite.
  required int? liveBuses,
  /// How sure the shown trip's live times are (see [certaintyOf]).
  required Certainty certainty,
  required VoidCallback onBack,
  required VoidCallback? onSwitchDirection,
  required ValueChanged<TripStop> onStopTap,
}) {
  final cs = Theme.of(context).colorScheme;
  final tt = Theme.of(context).textTheme;
  final trip = s.trip;
  return [
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 16, 12),
        child: Row(children: [
          M3EIconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: context.l10n.back,
            variant: M3EIconButtonVariant.standard,
            onPressed: onBack,
          ),
          const SizedBox(width: 4),
          LinePill(line: s.name, mode: s.mode, color: color, large: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (trip != null)
                Row(children: [
                  Icon(Icons.arrow_forward_rounded, size: 18, color: cs.onSurface),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(titleCase(trip.headsign),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: emphasized(context).titleMedium.copyWith(color: cs.onSurface)),
                  ),
                ]),
              Row(children: [
                if ((liveBuses ?? 0) > 0) ...[
                  Icon(Icons.sensors_rounded, size: 14, color: liveColor(context)),
                  const SizedBox(width: 4),
                ],
                Text(
                  [
                    if (liveBuses != null) context.l10n.busesLive(liveBuses),
                    if (trip != null) context.l10n.stopsCount(trip.stops.length),
                  ].join(' · '),
                  style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              ]),
            ]),
          ),
          if (onSwitchDirection != null)
            M3EIconButton(
              icon: const Icon(Icons.swap_horiz_rounded),
              tooltip: context.l10n.otherDirection,
              variant: M3EIconButtonVariant.tonal,
              onPressed: onSwitchDirection,
            ),
        ]),
      ),
    ),
    if (s.error != null)
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(s.error!, style: TextStyle(color: cs.error)),
        ),
      )
    else if (trip == null)
      SliverToBoxAdapter(child: SheetLoading(label: context.l10n.loadingLine))
    else
      M3EList.sliver(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: trip.stops.length,
        itemBuilder: (_, i) => _StopRow(
          stop: trip.stops[i],
          color: color,
          certainty: certainty,
          first: i == 0,
          last: i == trip.stops.length - 1,
        ),
        onTap: (i) => onStopTap(trip.stops[i]),
      ),
  ];
}

/// One stop of the trip: time (colored by how sure it is), a line with a
/// dot, the name. Stops the bus already left are dimmed.
class _StopRow extends StatelessWidget {
  const _StopRow({required this.stop, required this.color, required this.certainty, required this.first, required this.last});
  final TripStop stop;
  final Color color;
  final Certainty certainty;
  final bool first;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final passed = stop.time != null && stop.time!.isBefore(DateTime.now().subtract(const Duration(minutes: 1)));
    final timeColor =
        passed ? cs.outline : (certainty == Certainty.scheduled ? cs.onSurface : certaintyColor(context, certainty));
    return Opacity(
      opacity: passed ? 0.55 : 1,
      child: SizedBox(
        height: 48,
        child: Row(children: [
          const SizedBox(width: 16),
          SizedBox(
            width: 48,
            child: Text(stop.time == null ? '' : hm(stop.time!),
                style: emphasized(context).labelLarge.copyWith(color: timeColor)),
          ),
          SizedBox(
            width: 24,
            child: Stack(alignment: Alignment.center, children: [
              Column(children: [
                Expanded(child: Container(width: 4, color: first ? Colors.transparent : color)),
                Expanded(child: Container(width: 4, color: last ? Colors.transparent : color)),
              ]),
              Container(
                width: first || last ? 14 : 10,
                height: first || last ? 14 : 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: cs.surface,
                  border: Border.all(color: color, width: 3),
                ),
              ),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              titleCase(stop.name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (first || last ? emphasized(context).bodyLarge : Theme.of(context).textTheme.bodyLarge)
                  ?.copyWith(color: cs.onSurface),
            ),
          ),
          const SizedBox(width: 16),
        ]),
      ),
    );
  }
}
