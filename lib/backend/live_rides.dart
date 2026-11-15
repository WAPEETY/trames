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
/// (or walking, within [WalkPolicy.maxRideWalk]) and the feasible mix
/// arriving earliest wins; the rides before stay. With no feasible mix the journey keeps its buses and is
/// flagged [Itinerary.missedConnection].
///
///
/// With [earlier], a journey that works is still moved to an earlier bus
/// among a ride's alternatives (its line or another one doing the same
/// stretch) that the planner counts as left but, running late, can still be
/// caught (a bus the planner can catch has its own journey): the rides after it are chosen again for the
/// earliest arrival. It is taken when you arrive sooner, or no later while
/// leaving at most [WalkPolicy.earlierRideWait] before (that much more waiting on the
/// way rather than at the start). Not for a journey whose rides the user
/// picked.
///
/// Returns [it] itself when nothing moves and no ride is gone.
Itinerary applyLiveTimes(
  Itinerary it,
  LiveRide? Function(Leg ride) liveOf, {
  WalkCache? walks,
  WalkPolicy policy = kWalkPolicy,
  DateTime Function()? clock,
  int maxCombinations = 200,
  bool earlier = false,
}) {
  final base = it.base ?? it;
  var moved = false;
  bool gone(Leg ride) => liveOf(ride)?.gone ?? false;
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
              for (final a in l.alternatives)
                if (!gone(a.ride)) LegAlternative([for (final x in a.legs) live(x)]),
            ])
          : l,
  ];
  if (!moved && !earlier && !it.transitLegs.any(gone)) return it;
  final liveBase = Itinerary(
      start: base.start, end: base.end, legs: legs, transfers: base.transfers, hiddenBecause: base.hiddenBecause);

  final tv = TripVariants(liveBase,
      walks: walks, walkSlots: it.walkSlots, choices: it.rideChoices, policy: policy, clock: clock);

  int rideCount(int slot) => tv.variantCount(slot) - (tv.walkIndex(slot) == null ? 0 : 1);

  // Which buses a ride can swap to changes with the live times (a late one
  // can be caught again, another has left): keep the rides [it] uses, not
  // their positions among the variants.
  final used = it.transitLegs.toList();
  if (it.base != null && used.length == tv.slotCount - it.walkSlots.length) {
    final choice = tv.choices;
    var u = 0;
    for (var s = 0; s < tv.slotCount; s++) {
      if (it.walkSlots.contains(s)) continue;
      final ride = used[u++];
      for (var v = 0; v < rideCount(s); v++) {
        if (tv.rideOf(s, v).tripId == ride.tripId && tv.rideOf(s, v).planned == ride.planned) choice[s] = v;
      }
    }
    tv.restore(choice);
  }

  /// The ride [slot] uses now, or null when it is walked.
  Leg? chosen(int slot) {
    final c = tv.choiceOf(slot);
    if (tv.isWalk(slot, c)) return null;
    return rideCount(slot) == 0 ? tv.slotRide(slot) : tv.rideOf(slot, c);
  }

  /// Walking instead of a ride is only tried within the walk the user
  /// accepts ([WalkPolicy.maxRideWalk]); a walk the journey already had stays.
  bool allowed(int slot, int variant) {
    if (!tv.isWalk(slot, variant) || it.walkSlots.contains(slot)) return true;
    final cap = policy.maxRideWalk;
    return cap == null || tv.walkDurationOf(slot) <= cap;
  }

  List<int> goneSlots() => [
        for (var s = 0; s < tv.slotCount; s++)
          if (chosen(s) case final ride? when gone(ride)) s,
      ];
  bool ok() => tv.feasible && goneSlots().isEmpty;
  if (!moved && !it.transitLegs.any(gone) && !ok()) return it; // nothing live to re-plan around
  if (ok()) {
    if (earlier) _takeEarlierRide(tv, ok, chosen, rideCount, allowed, maxCombinations, policy.earlierRideWait, (clock ?? DateTime.now)());
    return !moved && _sameChoices(tv.current, it) ? it : tv.current;
  }

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
      if (allowed(s, v)) search(k + 1, List.of(choice)..[s] = v);
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

bool _sameChoices(Itinerary a, Itinerary b) =>
    a.transitLegs.map((l) => l.tripId).join(',') == b.transitLegs.map((l) => l.tripId).join(',') &&
    a.walkSlots.length == b.walkSlots.length &&
    a.walkSlots.containsAll(b.walkSlots);

/// Moves the working journey of [tv] to an earlier bus, one the planner
/// counts as left at [now], at the first ride that has one among its variants (see [applyLiveTimes]); the rides after it
/// take whichever variant arrives first. Leaves [tv] as it was when nothing
/// is worth it.
void _takeEarlierRide(
  TripVariants tv,
  bool Function() ok,
  Leg? Function(int slot) chosen,
  int Function(int slot) rideCount,
  bool Function(int slot, int variant) allowed,
  int maxCombinations,
  Duration wait,
  DateTime now,
) {
  final start = tv.choices;
  final was = tv.current;
  for (var s = 0; s < tv.slotCount; s++) {
    final ride = chosen(s);
    if (ride == null || ride.onBoard) continue;
    final sooner = [
      for (var v = 0; v < rideCount(s); v++)
        if (tv.rideOf(s, v).planned.isBefore(now) && tv.rideOf(s, v).start.isBefore(ride.start)) v,
    ];
    if (sooner.isEmpty) continue;
    List<int>? best;
    Itinerary? bestIt;
    var tried = 0;
    void search(int k, List<int> choice) {
      if (tried >= maxCombinations) return;
      if (k == tv.slotCount) {
        tried++;
        tv.restore(choice);
        if (!ok()) return;
        final now = tv.current;
        final worth = now.end.isBefore(was.end) ||
            (!now.end.isAfter(was.end) && was.start.difference(now.start) <= wait);
        if (!worth) return;
        final b = bestIt;
        if (b == null || now.end.isBefore(b.end) || (now.end == b.end && now.start.isBefore(b.start))) {
          best = List.of(choice);
          bestIt = now;
        }
        return;
      }
      for (var v = 0; v < tv.variantCount(k); v++) {
        if (allowed(k, v)) search(k + 1, List.of(choice)..[k] = v);
      }
    }

    for (final v in sooner) {
      search(s + 1, List.of(start)..[s] = v);
    }
    tv.restore(best ?? start);
    if (best != null) return;
  }
}
