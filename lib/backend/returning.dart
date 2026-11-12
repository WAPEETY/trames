import 'backend.dart';

/// When a bus coming back from the other direction counts for a timetable
/// departure (see [ReturnEstimator]).
class ReturnPolicy {
  const ReturnPolicy({
    this.turnaround = const Duration(minutes: 3),
    this.horizon = const Duration(minutes: 90),
    this.maxBusesPerTerminus = 4,
    this.maxTermini = 6,
    this.maxEndDistanceMeters = 300,
  });

  /// Least time at the terminus between arriving and leaving again.
  final Duration turnaround;

  /// Only departures leaving the terminus within this time are considered.
  final Duration horizon;

  /// Buses looked up per terminus (one trip request each), the ones closest
  /// to the end of their trip first.
  final int maxBusesPerTerminus;

  /// Termini looked at per refresh (soonest departures first).
  final int maxTermini;

  /// A bus's last stop counts as the terminus within this distance (the
  /// arrival and departure poles are often a road apart).
  final double maxEndDistanceMeters;
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
        .map((e) => e.time.isBefore(now) ? now : e.time) // already there
        .toList()
      ..sort();

    final out = <String, ReturnEstimate>{};
    var b = 0;
    for (final r in needing) {
      if (b >= ends.length) break;
      final ready = ends[b++].add(policy.turnaround);
      if (r.realtime) continue; // its forecast already counts on a bus
      out[r.tripId] = ready.isAfter(r.scheduled)
          ? ReturnEstimate(Certainty.estimated, delay: ready.difference(r.scheduled))
          : const ReturnEstimate(Certainty.returning);
    }
    return out;
  }
}
