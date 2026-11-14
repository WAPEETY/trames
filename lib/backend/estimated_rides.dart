import 'backend.dart';
import 'trip_variants.dart';
import 'walk_rules.dart';

/// Re-plans [it] around rides that run late by the app's own estimate
/// ([Certainty.estimated] in [estimates]: a bus coming back from the other
/// direction can only leave after the timetable).
///
/// Each such ride (and any such alternative) moves by its delay; the trip is
/// recomposed (walks re-timed, connections checked; see [TripVariants]). When
/// a later connection breaks, the rides after the first late one try their
/// other buses (or walking) and the feasible mix arriving earliest wins; the
/// late ride itself and the ones before it stay. With no feasible mix the
/// trip keeps its buses and is flagged [Itinerary.missedConnection].
///
/// Returns [it] unchanged when none of its rides is estimated.
Itinerary applyEstimatedRides(
  Itinerary it,
  Map<String, ReturnEstimate> estimates, {
  WalkCache? walks,
  WalkPolicy policy = kWalkPolicy,
  DateTime Function()? clock,
  int maxCombinations = 200,
}) {
  Duration? delayOf(Leg l) => !l.transit || l.realtime
      ? null
      : switch (estimates[l.tripId]) {
          ReturnEstimate(certainty: Certainty.estimated, :final delay) => delay,
          _ => null,
        };
  final base = it.base ?? it;
  var shifted = false;
  Leg shift(Leg l) {
    final alts = [
      for (final a in l.alternatives) LegAlternative([for (final x in a.legs) _moved(x, delayOf(x))]),
    ];
    final d = delayOf(l);
    if (d != null) shifted = true;
    return _moved(l, d).withAlternatives(alts);
  }

  final legs = [for (final l in base.legs) l.transit ? shift(l) : l];
  if (!shifted) return it;
  final shiftedBase = Itinerary(
      start: base.start, end: base.end, legs: legs, transfers: base.transfers, hiddenBecause: base.hiddenBecause);

  final tv = TripVariants(shiftedBase,
      walks: walks, walkSlots: it.walkSlots, choices: it.rideChoices, policy: policy, clock: clock);
  if (tv.feasible) return tv.current;

  // Repair: later slots try their variants; earlier ones and the first late
  // ride keep their choice.
  final start = tv.choices;
  final late = [for (var s = 0; s < tv.slotCount; s++) if (delayOf(tv.slotRide(s)) != null) s];
  final first = late.isEmpty ? 0 : late.first;
  final free = [for (var s = first + 1; s < tv.slotCount; s++) s];
  List<int>? best;
  DateTime? bestEnd;
  var bestChanges = 0;
  var tried = 0;
  void search(int k, List<int> choice) {
    if (tried >= maxCombinations) return;
    if (k == free.length) {
      tried++;
      tv.restore(choice);
      if (!tv.feasible) return;
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

Leg _moved(Leg l, Duration? delay) => delay == null ? l : l.movedTo(l.start.add(delay));
