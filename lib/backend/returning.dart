import 'backend.dart';

/// When a bus coming back from the other direction counts for a timetable
/// departure (see [ReturnEstimator]).
class ReturnPolicy {
  const ReturnPolicy({
    this.turnaround = const Duration(minutes: 3),
    this.horizon = const Duration(minutes: 60),
    this.maxBusesPerTerminus = 4,
    this.maxTermini = 6,
    this.maxEndDistanceMeters = 300,
    this.maxEstimatedDelay = const Duration(minutes: 60),
  });

  /// Least time at the terminus between arriving and leaving again.
  final Duration turnaround;

  /// Look-ahead: only departures leaving the terminus, and buses reaching
  /// it, within this time are considered; beyond it there's no prediction.
  final Duration horizon;

  /// Buses looked up per terminus (one trip request each), the ones closest
  /// to the end of their trip first.
  final int maxBusesPerTerminus;

  /// Termini looked at per refresh (soonest departures first).
  final int maxTermini;

  /// A bus's last stop counts as the terminus within this distance (the
  /// arrival and departure poles are often a road apart).
  final double maxEndDistanceMeters;

  /// A bus that could only leave this much later than the timetable is more
  /// likely to run a later departure (another bus covers this one): the
  /// departure stays on the timetable and the bus goes to the next one.
  final Duration maxEstimatedDelay;
}

const kReturnPolicy = ReturnPolicy();

/// A line leaving a terminus: what [ReturnEstimator.estimate] looks at.
class ReturnQuery {
  const ReturnQuery(this.line, this.origin);
  final String line;
  final TripOrigin origin;

  String get key => '${line.toLowerCase()}|${origin.stopId}';
}

/// Timetable-only departures that a bus now running the other way could
/// still make: [Certainty.returning] when it reaches the terminus (plus
/// [ReturnPolicy.turnaround]) before the timetabled start, else
/// [Certainty.estimated] with the start pushed back to when it can leave.
///
/// Per line and terminus: the line's departures from the terminus in order;
/// the buses of the line heading there (other direction, last stop near
/// the terminus), by when they arrive. The earliest bus goes to the earliest
/// departure still needing one: departures with their own bus (on it or
/// parked at the terminus) need none; a live departure with no bus on it yet
/// takes one but keeps its own certainty; a timetable one gets red/purple.
/// No bus left: timetable, as before.
class ReturnEstimator {
  ReturnEstimator(this.source, {this.policy = kReturnPolicy, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final ReturnSource source;
  final ReturnPolicy policy;
  final DateTime Function() _clock;

  /// Results by raw trip id. [vehicles]: live buses by raw trip id.
  Future<Map<String, ReturnEstimate>> estimate(Iterable<ReturnQuery> queries, Map<String, Vehicle> vehicles) async {
    final unique = <String, ReturnQuery>{};
    for (final q in queries) {
      unique.putIfAbsent(q.key, () => q);
    }
    final results = await Future.wait(unique.values.take(policy.maxTermini).map((q) async {
      try {
        return await _one(q, vehicles);
      } catch (_) {
        return const <String, ReturnEstimate>{}; // that terminus stays timetable
      }
    }));
    return {for (final r in results) ...r};
  }

  Future<Map<String, ReturnEstimate>> _one(ReturnQuery q, Map<String, Vehicle> vehicles) async {
    final now = _clock();
    final line = q.line.toLowerCase();
    final runs = (await source.departuresFrom(q.origin.stopId))
        .where((r) =>
            r.line.toLowerCase() == line &&
            !r.scheduled.isBefore(now.subtract(const Duration(minutes: 1))) &&
            r.scheduled.isBefore(now.add(policy.horizon)))
        .toList()
      ..sort((a, b) => a.scheduled.compareTo(b.scheduled));
    // Departures whose bus is already on them (parked here) need no other.
    final needing = runs.where((r) => !vehicles.containsKey(r.tripId)).toList();
    if (!needing.any((r) => !r.realtime)) return const {};

    final direction = runs.map((r) => r.directionId).nonNulls.firstOrNull;
    final own = {for (final r in runs) r.tripId};
    final candidates = vehicles.values
        .where((v) =>
            v.routeShortName?.toLowerCase() == line &&
            !own.contains(v.tripId) &&
            (direction == null || v.directionId == null || v.directionId != direction))
        .toList()
      // Closest to the end of its trip first.
      ..sort((a, b) => (b.stopSequence ?? 0).compareTo(a.stopSequence ?? 0));
    final ends = (await Future.wait(candidates
            .take(policy.maxBusesPerTerminus.clamp(0, needing.length))
            .map((v) => source.tripEnd(v).catchError((Object _) => null))))
        .nonNulls
        .where((e) => distanceMeters(e.position, q.origin.position) <= policy.maxEndDistanceMeters)
        // A run resolved to another service day (around midnight) ends far
        // off: not this bus's trip.
        .where((e) => e.time.isBefore(now.add(policy.horizon)))
        .map((e) => e.time.isBefore(now) ? now : e.time) // already there
        .toList()
      ..sort();

    final out = <String, ReturnEstimate>{};
    var b = 0;
    for (final r in needing) {
      if (b >= ends.length) break;
      final ready = ends[b].add(policy.turnaround);
      final delay = ready.difference(r.scheduled);
      // Too late for this one (and every later bus is later still): it
      // stays on the timetable, this bus goes to the next departure. A live
      // departure keeps its bus whatever the timetable says.
      if (!r.realtime && delay > policy.maxEstimatedDelay) continue;
      b++;
      if (r.realtime) continue; // its forecast already counts on a bus
      out[r.tripId] = delay > Duration.zero
          ? ReturnEstimate(Certainty.estimated, delay: delay)
          : const ReturnEstimate(Certainty.returning);
    }
    return out;
  }
}
