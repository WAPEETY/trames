import 'backend.dart';
import 'trip_variants.dart';
import 'walk_rules.dart';

/// What the live data says about one ride of a journey: when it really
/// leaves its boarding stop ([start]) and reaches the stop you get off at
/// ([end]); null = no better time than the planner's. Or that it can't be
/// caught any more ([gone]: its bus has passed the boarding stop, the trip
/// is cancelled or skips it).
class LiveRide {
  const LiveRide({this.start, this.end, this.gone = false});
  final DateTime? start;
  final DateTime? end;
  final bool gone;
}

/// Tramite's trip is another run than the planner's ride when their
/// timetable times at the boarding stop are this far apart.
const _sameRun = Duration(minutes: 3);

/// Which times a ride gets, from Tramite's view of its [trip] (null: not
/// followed, or not covered). At each of its two stops:
///  * Tramite has a live time: that one, whatever the planner says;
///  * only the planner has a live time: the planner's;
///  * neither: Tramite's inferred time (a known bus should run it) when
///    there is one, else the timetable.
/// A time more than 12 hours from the timetable is a feed error and is
/// not used. A stop the trip calls at twice (loop lines) is taken at the visit the
/// planner means, by its timetable time. Null when the planner's times
/// stand.
LiveRide? liveRideFor(Leg leg, TramiteTrip? trip) {
  if (trip == null || !leg.transit) return null;
  if (leg.onBoard) {
    // The bus you're on: nothing to catch, only when it gets you there
    // (looked for among the stops still ahead of the bus).
    final seq = trip.busSequence;
    final ahead = seq == null ? 0 : trip.stops.indexWhere((s) => s.sequence >= seq);
    final a = ahead < 0 ? null : trip.visit(leg.toStopId, leg.scheduledEnd, from: ahead, arrival: true);
    return a != null && trip.stops[a].realtime && trip.stops[a].plausible ? LiveRide(end: trip.stops[a].arrival) : null;
  }
  final b = trip.visit(leg.fromStopId, leg.scheduledStart);
  if (b == null) return null;
  final board = trip.stops[b];
  if (board.scheduledDeparture.difference(leg.scheduledStart).abs() > _sameRun) return null;
  if (trip.cancelled || board.cancelled || trip.passed(board)) return const LiveRide(gone: true);
  final a = trip.visit(leg.toStopId, leg.scheduledEnd, from: b + 1, arrival: true);
  final alight = a == null ? null : trip.stops[a];
  bool usable(TramiteTripStop s) => s.plausible && (s.realtime || (s.inferred && !leg.realtime));
  final start = usable(board) ? board.departure : null;
  final end = alight != null && usable(alight) ? alight.arrival : null;
  return start == null && end == null ? null : LiveRide(start: start, end: end);
}

/// Whether the first ride of [it] can't be caught any more.
bool firstRideGone(Itinerary it, LiveRide? Function(Leg ride) liveOf) {
  final first = it.transitLegs.firstOrNull;
  return first != null && (liveOf(first)?.gone ?? false);
}

/// [it] with its rides at their live times ([liveOf], see [liveRideFor]),
/// re-planned around them.
///
/// Each ride (and each alternative) moves to its live times, or back to the
/// planner's when there is none any more; the journey is recomposed (walks
/// re-timed, connections checked; see [TripVariants]). When a connection
/// breaks, or a ride is gone, the rides from there on try their other buses
/// (or walking) and the feasible mix arriving earliest wins; the rides
/// before stay. With no feasible mix the journey keeps its buses and is
/// flagged [Itinerary.missedConnection].
///
/// Returns [it] itself when nothing moves and no ride is gone.
Itinerary applyLiveTimes(
  Itinerary it,
  LiveRide? Function(Leg ride) liveOf, {
  WalkCache? walks,
  WalkPolicy policy = kWalkPolicy,
  DateTime Function()? clock,
  int maxCombinations = 200,
}) {
  final base = it.base ?? it;
  var moved = false;
  Leg live(Leg l) {
    if (!l.transit) return l;
    final now = liveOf(l);
    final at = l.at(now?.start, now?.end);
    if (!identical(at, l)) moved = true;
    return at;
  }

  final legs = [
    for (final l in base.legs)
      l.transit
          ? live(l).withAlternatives([
              for (final a in l.alternatives) LegAlternative([for (final x in a.legs) live(x)]),
            ])
          : l,
  ];
  bool gone(Leg ride) => liveOf(ride)?.gone ?? false;
  if (!moved && !it.transitLegs.any(gone)) return it;
  final liveBase = Itinerary(
      start: base.start, end: base.end, legs: legs, transfers: base.transfers, hiddenBecause: base.hiddenBecause);

  final tv = TripVariants(liveBase,
      walks: walks, walkSlots: it.walkSlots, choices: it.rideChoices, policy: policy, clock: clock);

  /// The ride [slot] uses now, or null when it is walked.
  Leg? chosen(int slot) {
    final c = tv.choiceOf(slot);
    if (tv.isWalk(slot, c)) return null;
    final rides = tv.variantCount(slot) - (tv.walkIndex(slot) == null ? 0 : 1);
    return rides == 0 ? tv.slotRide(slot) : tv.rideOf(slot, c);
  }

  List<int> goneSlots() => [
        for (var s = 0; s < tv.slotCount; s++)
          if (chosen(s) case final ride? when gone(ride)) s,
      ];
  bool ok() => tv.feasible && goneSlots().isEmpty;
  if (ok()) return tv.current;

  // Repair: a gone ride and the rides after it, and the rides after one
  // that runs late, try their variants; a ride that runs early may have
  // left before you get there, so it tries its own too. Earlier ones stay.
  final start = tv.choices;
  var first = tv.slotCount;
  for (final s in goneSlots()) {
    if (s < first) first = s;
  }
  for (var s = 0; s < tv.slotCount; s++) {
    final ride = tv.slotRide(s);
    if (ride.start == ride.planned && ride.end == ride.plannedArrival) continue;
    final from = ride.start.isBefore(ride.planned) ? s : s + 1;
    if (from < first) first = from;
  }
  if (first == tv.slotCount) first = 0;
  final free = [for (var s = first; s < tv.slotCount; s++) s];
  List<int>? best;
  DateTime? bestEnd;
  var bestChanges = 0;
  var tried = 0;
  void search(int k, List<int> choice) {
    if (tried >= maxCombinations) return;
    if (k == free.length) {
      tried++;
      tv.restore(choice);
      if (!ok()) return;
      final end = tv.current.end;
      final changes = [for (final s in free) if (choice[s] != start[s]) s].length;
      if (bestEnd == null || end.isBefore(bestEnd!) || (end == bestEnd && changes < bestChanges)) {
        best = List.of(choice);
        bestEnd = end;
        bestChanges = changes;
      }
      return;
    }
    final s = free[k];
    for (var v = 0; v < tv.variantCount(s); v++) {
      search(k + 1, List.of(choice)..[s] = v);
    }
  }

  search(0, start);
  if (best != null) {
    tv.restore(best!);
    return tv.current;
  }
  tv.restore(start);
  return tv.current.withMissedConnection();
}
