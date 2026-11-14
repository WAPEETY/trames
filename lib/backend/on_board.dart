import 'dart:math' as math;

import 'package:maplibre_gl/maplibre_gl.dart';

import 'backend.dart';

/// Planning a journey while riding a vehicle ([OnBoardRide]).
///
/// Planners start a search from a place, not from a vehicle. The trick: tell
/// the planner the stops you can reach, which are the ones the vehicle still
/// calls at, each reached when the vehicle gets there. These are the
/// *offsets* below. The planner picks where to get off, and its itineraries
/// then start with a fake first leg to that stop, which [fromOnBoardPlan]
/// replaces with the ride itself.
///
/// What the planner gets wrong, fixed here:
///  * it can't walk on from the stop you get off at, so stops a short walk
///    from the vehicle's stops are offsets too ([onBoardOffsets]);
///  * it sees no change when you get off and board something else (the
///    vehicle you're on is invisible to it): the ride is put back in and
///    changes are counted again;
///  * offsets include time to get off and change ([kOnBoardTransferBuffer]),
///    so the planner "misses" the vehicle you're on at every stop: staying
///    on can come back as a detour that catches it again further on (folded
///    back into one ride), or not at all;
///  * staying on and changing both look like "no change" to it, so a change
///    one minute faster hides staying on: [stayOnBoard] builds that option
///    itself, and [preferStayingOn] drops changes that don't clearly pay.

/// Time to get off and catch the next vehicle (on top of any walk).
const kOnBoardTransferBuffer = Duration(minutes: 1);

/// Staying on and then walking further than this isn't "the bus takes you
/// there": it competes with the other routes like any of them.
const kStayOnMaxWalk = Duration(minutes: 10);

/// How far from the vehicle's stops other stops count as reachable on foot.
const kOnBoardWalkMeters = 350.0;

/// Street walks are longer than the straight line by about this much.
const _walkDetour = 1.3;

/// The vehicle you ride, at [now]: where it is and the stops still ahead.
class OnBoardTrip {
  OnBoardTrip(this.ride, this.info, {required this.now}) {
    final first = info.stops.indexWhere((s) => s.time != null && !s.time!.isBefore(now));
    remaining = first < 0 ? const [] : [for (final s in info.stops.skip(first)) if (s.time != null) s];
    position = _whereNow(first);
  }

  final OnBoardRide ride;
  final TripInfo info;
  final DateTime now;

  /// Stops not reached yet (by their live times when known), in order.
  late final List<TripStop> remaining;

  /// Where the vehicle should be now: between the last stop it passed and
  /// the next, by their times.
  late final LatLng position;

  LatLng _whereNow(int next) {
    if (next < 0) return info.stops.isEmpty ? const LatLng(0, 0) : info.stops.last.position;
    final b = info.stops[next];
    if (next == 0) return b.position;
    final a = info.stops[next - 1];
    if (a.time == null || !b.time!.isAfter(a.time!)) return b.position;
    final f = (now.difference(a.time!).inSeconds / b.time!.difference(a.time!).inSeconds).clamp(0.0, 1.0);
    return LatLng(
      a.position.latitude + (b.position.latitude - a.position.latitude) * f,
      a.position.longitude + (b.position.longitude - a.position.longitude) * f,
    );
  }

  /// Index in [remaining] of the stop with [stopId] (the first, on loops).
  int? indexOf(String? stopId) {
    if (stopId == null) return null;
    final i = remaining.indexWhere((s) => s.stopId == stopId);
    return i < 0 ? null : i;
  }

  /// Whether [leg] rides this same vehicle run.
  bool isThisRun(Leg leg) =>
      leg.transit &&
      (leg.backendTripId == ride.backendTripId || (leg.tripId != null && leg.tripId == ride.tripId));

  /// The ride from here to [remaining]\[[k]\], getting off there.
  Leg rideTo(int k) {
    final stop = remaining[k];
    final path = approachPath(info.points, position, stop.position);
    final points = path.length >= 2 ? path : [position, stop.position];
    var meters = 0.0;
    for (var i = 1; i < points.length; i++) {
      meters += distanceMeters(points[i - 1], points[i]);
    }
    return Leg(
      mode: info.mode.isEmpty ? ride.mode : info.mode,
      transit: true,
      onBoard: true,
      start: now,
      end: stop.time!,
      fromName: remaining.first.name,
      toName: stop.name,
      from: position,
      to: stop.position,
      points: points,
      distanceMeters: meters,
      routeShortName: ride.line,
      headsign: info.headsign.isEmpty ? ride.headsign : info.headsign,
      tripId: ride.tripId,
      backendTripId: ride.backendTripId,
      realtime: stop.live,
      arrivalDelaySeconds: stop.delaySeconds,
      intermediateStops: k,
      // Live data for this ride is followed at the next stop.
      fromStopId: remaining.first.stopId,
      toStopId: stop.stopId,
    );
  }
}

/// A stop the planner may start from: [index] is the vehicle's stop where
/// you get off, [walk] the walk on from there to [stopId] (zero when it is
/// that stop), [offset] how long from now until you can board there.
class OnBoardOffset {
  const OnBoardOffset({
    required this.stopId,
    required this.index,
    required this.offset,
    this.walk = Duration.zero,
    this.name = '',
    this.position,
  });

  final String stopId;
  final int index;
  final Duration offset;
  final Duration walk;

  /// The stop walked to (when [walk] isn't zero).
  final String name;
  final LatLng? position;
}

/// Offsets for [trip], by stop id: every stop still ahead, when the vehicle
/// gets there, plus the [nearby] stops within [maxMeters] of one of them,
/// when you could be there on foot at [walkSpeed] m/s (from whichever stop
/// is quickest); all with [kOnBoardTransferBuffer] to change.
Map<String, OnBoardOffset> onBoardOffsets(
  OnBoardTrip trip,
  Iterable<Stop> nearby, {
  double walkSpeed = 1.2,
  double maxMeters = kOnBoardWalkMeters,
}) {
  final out = <String, OnBoardOffset>{};
  final stops = trip.remaining;
  for (var k = 0; k < stops.length; k++) {
    final id = stops[k].stopId;
    if (id == null || out.containsKey(id)) continue; // a loop: the first visit
    out[id] = OnBoardOffset(stopId: id, index: k, offset: stops[k].time!.difference(trip.now) + kOnBoardTransferBuffer);
  }
  for (final s in nearby) {
    if (out.containsKey(s.id)) continue;
    OnBoardOffset? best;
    for (var k = 0; k < stops.length; k++) {
      final d = distanceMeters(s.position, stops[k].position);
      if (d > maxMeters) continue;
      final walk = Duration(seconds: (d * _walkDetour / walkSpeed).round());
      final offset = stops[k].time!.difference(trip.now) + walk + kOnBoardTransferBuffer;
      if (best == null || offset < best.offset) {
        best = OnBoardOffset(stopId: s.id, index: k, offset: offset, walk: walk, name: s.name, position: s.position);
      }
    }
    if (best != null) out[s.id] = best;
  }
  return out;
}

/// Turns a planner itinerary that started from [offsets] into one that
/// starts on board: the ride to where you get off (and the walk on, if any)
/// in place of the planner's fake first leg; staying on folded into one
/// ride. Null when it can't be used: it starts from a stop that isn't an
/// offset, or leaves too little time to change ([buffer]; the offsets
/// already include it, so only an inconsistent answer fails this).
Itinerary? fromOnBoardPlan(
  Itinerary raw,
  OnBoardTrip trip,
  Map<String, OnBoardOffset> offsets, {
  Duration buffer = kOnBoardTransferBuffer,
}) {
  final first = raw.legs.indexWhere((l) => l.transit);
  if (first < 0) return null;
  var rest = raw.legs.sublist(first);
  final List<Leg> head;
  final same = rest.lastIndexWhere(trip.isThisRun);
  if (same >= 0) {
    // On this vehicle again later (after a detour, or straight away): just
    // stay on until where that ride ends.
    final k = trip.indexOf(rest[same].toStopId);
    if (k == null) return null;
    head = [trip.rideTo(k)];
    rest = rest.sublist(same + 1);
  } else {
    final o = offsets[rest.first.fromStopId];
    if (o == null) return null;
    final ride = trip.rideTo(o.index);
    final ready = ride.end.add(o.walk).add(buffer);
    if (rest.first.start.isBefore(ready)) return null;
    head = [
      ride,
      if (o.walk > Duration.zero)
        Leg(
          mode: 'WALK',
          transit: false,
          start: ride.end,
          end: ride.end.add(o.walk),
          fromName: ride.toName,
          toName: o.name,
          from: ride.to,
          to: o.position ?? ride.to,
          points: [ride.to, o.position ?? ride.to],
          distanceMeters: o.position == null ? 0 : distanceMeters(ride.to, o.position!),
        ),
    ];
  }
  final legs = [...head, ...rest];
  return Itinerary(
    start: trip.now,
    end: rest.isEmpty ? head.last.end : raw.end,
    legs: legs,
    transfers: legs.where((l) => l.transit).length - 1,
  );
}

/// Staying on and walking from the best stop: of the [candidates] stops
/// still ahead nearest [to] (and within [maxWalkMeters]), the one where
/// getting off and walking arrives first. Null when none is near enough or
/// no walk is known.
Future<Itinerary?> stayOnBoard(
  OnBoardTrip trip,
  LatLng to,
  WalkCache walks, {
  String toName = '',
  int candidates = 3,
  double maxWalkMeters = 1500,
}) async {
  final near = [
    for (var k = 0; k < trip.remaining.length; k++)
      if (distanceMeters(trip.remaining[k].position, to) <= maxWalkMeters) k,
  ]..sort((a, b) => distanceMeters(trip.remaining[a].position, to)
      .compareTo(distanceMeters(trip.remaining[b].position, to)));
  final ks = near.take(candidates).toList();
  if (ks.isEmpty) return null;
  await walks.fetch([for (final k in ks) (trip.remaining[k].position, to)]);
  ({int k, WalkRoute walk, DateTime end})? best;
  for (final k in ks) {
    final walk = walks.lookup(trip.remaining[k].position, to);
    if (walk == null) continue;
    final end = trip.remaining[k].time!.add(walk.duration);
    if (best == null || end.isBefore(best.end)) best = (k: k, walk: walk, end: end);
  }
  if (best == null) return null;
  final ride = trip.rideTo(best.k);
  return Itinerary(
    start: trip.now,
    end: best.end,
    transfers: 0,
    legs: [
      ride,
      Leg(
        mode: 'WALK',
        transit: false,
        start: ride.end,
        end: best.end,
        fromName: ride.toName,
        toName: toName,
        from: ride.to,
        to: to,
        points: best.walk.points.isEmpty ? [ride.to, to] : best.walk.points,
        distanceMeters: best.walk.distanceMeters,
      ),
    ],
  );
}

/// How much sooner getting off and changing must arrive than staying on:
/// max([floor], [share] × the time left when staying on), for each change.
class StayOnPolicy {
  const StayOnPolicy({this.floor = const Duration(minutes: 5), this.share = 0.15});
  final Duration floor;
  final double share;

  Duration threshold(Duration remaining) {
    final scaled = Duration(seconds: (remaining.inSeconds * share).round());
    return scaled > floor ? scaled : floor;
  }
}

const kStayOnPolicy = StayOnPolicy();

/// Staying on the vehicle until the end of the trip, then a short walk at
/// most ([kStayOnMaxWalk]).
bool staysOnBoard(Itinerary it) {
  final rides = it.transitLegs.toList();
  if (rides.length != 1 || !rides.first.onBoard) return false;
  final walk = it.legs.where((l) => !l.transit).fold(Duration.zero, (d, l) => d + l.duration);
  return walk <= kStayOnMaxWalk;
}

/// Keeps staying on (the earliest-arriving way) and only the itineraries
/// that beat it by [StayOnPolicy.threshold] per change. Unchanged when no
/// itinerary stays on.
List<Itinerary> preferStayingOn(List<Itinerary> all, {required DateTime now, StayOnPolicy policy = kStayOnPolicy}) {
  Itinerary? stay;
  for (final it in all.where(staysOnBoard)) {
    if (stay == null || it.end.isBefore(stay.end)) stay = it;
  }
  if (stay == null) return all;
  final bar = policy.threshold(stay.end.difference(now));
  return [
    for (final it in all)
      if (staysOnBoard(it) || !it.end.isAfter(stay.end.subtract(bar * math.max(1, it.transfers)))) it,
  ];
}

/// The trip you're on has no stops left (it ended, or you passed them all).
class OnBoardTripOver implements Exception {
  const OnBoardTripOver();
  @override
  String toString() => 'The trip has no stops left';
}
