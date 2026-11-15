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

  /// Tramite's view of the shown trip, when it covers it: its times.
  TramiteTrip? live;

  /// The shown trip's stops with the times to show: Tramite's where it has
  /// a live one, else the planner's (see [stopsAtLiveTimes]).
  List<TripStop> get stops {
    final t = trip, seen = live;
    if (t == null) return const [];
    return seen == null ? t.stops : stopsAtLiveTimes(t.stops, matchTripStops(t.stops, seen), arrival: false);
  }

  bool loading = true;
  String? error;

  /// GTFS direction id -> a trip id running that way (from live vehicles).
  Map<int, String> directions = {};

  /// Every live bus of the line, both directions; the map shows the ones
  /// going the way of the shown trip.
  List<({Vehicle vehicle, String? color})> buses = const [];

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
  /// The bus running the shown trip, when it's live: drawn in the stop list.
  Vehicle? bus,
}) {
  final cs = Theme.of(context).colorScheme;
  final tt = Theme.of(context).textTheme;
  final trip = s.trip;
  final stops = s.stops;
  final place = trip == null || bus == null ? null : busPlaceOnTrip(stops, bus);
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
      SliverToBoxAdapter(
        child: _StopList(stops: stops, color: color, certainty: certainty, place: place, onStopTap: onStopTap),
      ),
  ];
}

/// The trip's stops as a card list, with the bus on it: in place of the
/// dot when it's at a stop, else over the gap between the two cards it
/// runs between. The cards clip their content, so that one is drawn on a
/// layer above the list, where the measured line of the stop it left ends.
class _StopList extends StatefulWidget {
  const _StopList(
      {required this.stops, required this.color, required this.certainty, required this.place, required this.onStopTap});
  final List<TripStop> stops;
  final Color color;
  final Certainty certainty;
  final ({int index, bool atStop})? place;
  final ValueChanged<TripStop> onStopTap;

  @override
  State<_StopList> createState() => _StopListState();
}

class _StopListState extends State<_StopList> {
  static const _gap = M3EListCardListTheme.defaultGap;
  final _stack = GlobalKey();
  final _lineAbove = GlobalKey(); // the timeline of the stop the bus left

  /// Centre of the gap the bus is over, in the stack; null: none drawn.
  Offset? _bus;

  int? get _leftIndex => switch (widget.place) {
        (index: final i, atStop: false) when i > 0 => i - 1,
        _ => null,
      };

  void _measure() {
    if (!mounted) return;
    Offset? at;
    final line = _lineAbove.currentContext?.findRenderObject() as RenderBox?;
    final stack = _stack.currentContext?.findRenderObject() as RenderBox?;
    if (_leftIndex != null && line != null && stack != null && line.attached && stack.attached) {
      at = stack.globalToLocal(line.localToGlobal(line.size.bottomCenter(Offset.zero))) + const Offset(0, _gap / 2);
    }
    if (at != _bus && (at == null || _bus == null || (at - _bus!).distance > 0.5)) setState(() => _bus = at);
  }

  @override
  Widget build(BuildContext context) {
    final stops = widget.stops;
    final place = widget.place;
    final left = _leftIndex;
    final bus = _bus;
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    return Stack(key: _stack, clipBehavior: Clip.none, children: [
      M3EList(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        gap: _gap,
        itemCount: stops.length,
        itemBuilder: (_, i) => _StopRow(
          stop: stops[i],
          color: widget.color,
          certainty: widget.certainty,
          first: i == 0,
          last: i == stops.length - 1,
          busHere: place != null && place.atStop && place.index == i,
          lineKey: i == left ? _lineAbove : null,
        ),
        onTap: (i) => widget.onStopTap(stops[i]),
      ),
      if (left != null && bus != null)
        Positioned(
          left: bus.dx - _BusBadge.size / 2,
          top: bus.dy - _BusBadge.size / 2,
          child: IgnorePointer(child: _BusBadge(color: _busColor(context, widget.certainty))),
        ),
    ]);
  }
}

/// The bus badge's color: like its live times, live green on timetable.
Color _busColor(BuildContext context, Certainty c) =>
    certaintyColor(context, c == Certainty.scheduled ? Certainty.moving : c);

/// One stop of the trip: time (colored by how sure it is), a line with a
/// dot, the name. Stops the bus already left are dimmed. The bus replaces
/// the dot when it's at the stop.
/// [lineKey] marks the timeline, to place a bus between stops (see
/// [_StopList]).
class _StopRow extends StatelessWidget {
  const _StopRow({
    required this.stop,
    required this.color,
    required this.certainty,
    required this.first,
    required this.last,
    this.busHere = false,
    this.lineKey,
  });
  final TripStop stop;
  final Color color;
  final Certainty certainty;
  final bool first;
  final bool last;
  final bool busHere;
  final Key? lineKey;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final passed = stop.time != null && stop.time!.isBefore(DateTime.now().subtract(const Duration(minutes: 1)));
    final timeColor =
        passed ? cs.outline : (certainty == Certainty.scheduled ? cs.onSurface : certaintyColor(context, certainty));
    final dot = Container(
      width: first || last ? 14 : 10,
      height: first || last ? 14 : 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: cs.surface,
        border: Border.all(color: color, width: 3),
      ),
    );
    return Opacity(
      opacity: passed && !busHere ? 0.55 : 1,
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
            key: lineKey,
            width: 24,
            child: Stack(alignment: Alignment.center, children: [
              Column(children: [
                Expanded(child: Container(width: 4, color: first ? Colors.transparent : color)),
                Expanded(child: Container(width: 4, color: last ? Colors.transparent : color)),
              ]),
              busHere ? _BusBadge(color: _busColor(context, certainty)) : dot,
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

/// The bus on the stop list's line: a filled circle with a bus icon,
/// colored like its live times.
class _BusBadge extends StatelessWidget {
  const _BusBadge({required this.color});
  final Color color;
  static const size = 24.0;

  @override
  Widget build(BuildContext context) {
    final fg = ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Colors.white : Colors.black;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2),
      ),
      child: Icon(Icons.directions_bus_rounded, size: 14, color: fg),
    );
  }
}
