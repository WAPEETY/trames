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
///    itself, and [checkStayingOn] (the same rule as for any journey) puts
///    changes that don't clearly pay under "show more".

/// Time to get off and catch the next vehicle (on top of any walk).
const kOnBoardTransferBuffer = Duration(minutes: 1);

/// Staying on and then walking further than this isn't "the bus takes you
/// there" (tagged and listed first in on-board mode). The rule that hides
/// journeys uses the walking preference instead ([WalkPolicy.maxStayOnWalk]).
const kStayOnMaxWalk = Duration(minutes: 20);

/// How far from the vehicle's stops other stops count as reachable on foot.
const kOnBoardWalkMeters = 350.0;

/// Street walks are longer than the straight line by about this much.
const _walkDetour = 1.3;

/// The vehicle you ride, at [now]: where it is and the stops still ahead.
///
/// With [live] (Tramite's view of the run) nothing is guessed: the bus is
/// where its GPS says, the stops ahead start at the one the feed says it's
/// at or heading to, and each stop's time is Tramite's when it has a live
/// one, else the planner's (its own live time, or the timetable). Without
/// it, or where it says nothing, the stops ahead are those whose time is
/// still to come and the bus is placed between two stops by their times.
///
/// With [boardedAt] it's a ride you will board at that stop at [now] (a
/// journey's ride, checked like the bus you're on): the stops ahead are
/// those after it.
class OnBoardTrip {
  OnBoardTrip(this.ride, this.info, {required this.now, String? boardedAt, this.live}) {
    final at = boardedAt == null ? -1 : _boardingIndex(boardedAt);
    if (at >= 0) {
      _stops = info.stops;
      remaining = [for (final s in info.stops.skip(at + 1)) if (s.time != null) s];
      position = info.stops[at].position;
      return;
    }
    final seen = live;
    final match = seen == null ? null : _matchStops(seen);
    _stops = match == null
        ? info.stops
        : [
            for (var i = 0; i < info.stops.length; i++)
              switch (match[i]) {
                final m? when m.realtime || (m.inferred && !info.stops[i].live) => TripStop(
                    name: info.stops[i].name,
                    position: info.stops[i].position,
                    stopId: info.stops[i].stopId,
                    time: m.arrival,
                    scheduled: m.scheduledArrival,
                    live: m.realtime,
                  ),
                _ => info.stops[i],
              },
          ];
    // The stop the bus is at or heading to, by the feed; else by the times.
    final seq = seen?.busSequence;
    final first = seq != null && match != null
        ? match.indexWhere((m) => m != null && m.sequence >= seq)
        : _stops.indexWhere((s) => s.time != null && !s.time!.isBefore(now));
    // A late bus is still to come at stops whose time has gone by: never
    // before now, never before the stop before.
    var floor = now;
    remaining = [
      if (first >= 0)
        for (var i = first; i < _stops.length; i++)
          if (_stops[i].time != null && !(match?[i]?.cancelled ?? false))
            _stops[i].notBefore(floor = _stops[i].time!.isAfter(floor) ? _stops[i].time! : floor),
    ];
    position = seen?.bus?.position ?? _whereNow(first);
  }

  /// Tramite's view of this run, when it covers it.
  final TramiteTrip? live;

  /// [info]'s stops with the times in use (see the class comment).
  late final List<TripStop> _stops;

  /// For each of [info]'s stops, the same stop in [seen] (both in trip
  /// order, so a stop on the trip twice pairs up visit by visit); null for
  /// a stop Tramite's timetable doesn't have.
  List<TramiteTripStop?> _matchStops(TramiteTrip seen) {
    final out = List<TramiteTripStop?>.filled(info.stops.length, null);
    var j = 0;
    for (var i = 0; i < info.stops.length; i++) {
      for (var k = j; k < seen.stops.length; k++) {
        if (seen.stops[k].stopId == info.stops[i].stopId) {
          out[i] = seen.stops[k];
          j = k + 1;
          break;
        }
      }
    }
    return out;
  }

  /// The visit of [stopId] nearest [now] (a stop can be on a loop twice).
  int _boardingIndex(String stopId) {
    var best = -1;
    for (var i = 0; i < info.stops.length; i++) {
      final s = info.stops[i];
      if (s.stopId != stopId) continue;
      final d = s.time?.difference(now).abs();
      if (best < 0 || (d != null && d < (info.stops[best].time?.difference(now).abs() ?? d))) best = i;
    }
    return best;
  }

  final OnBoardRide ride;
  final TripInfo info;
  final DateTime now;

  /// Stops not reached yet (by their live times when known), in order.
  late final List<TripStop> remaining;

  /// Where the vehicle is: its live position, else where it should be now,
  /// between the last stop it passed and the next, by their times.
  late final LatLng position;

  LatLng _whereNow(int next) {
    if (next < 0) return _stops.isEmpty ? const LatLng(0, 0) : _stops.last.position;
    final b = _stops[next];
    if (next == 0) return b.position;
    final a = _stops[next - 1];
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

  /// The ride from here to [remaining]\[[k]\], getting off there;
  /// [onBoard] when it's the bus you're on now.
  Leg rideTo(int k, {bool onBoard = true}) {
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
      onBoard: onBoard,
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
  Duration? maxWalk,
  bool onBoard = true,
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
    if (walk == null || (maxWalk != null && walk.duration > maxWalk)) continue;
    final end = trip.remaining[k].time!.add(walk.duration);
    if (best == null || end.isBefore(best.end)) best = (k: k, walk: walk, end: end);
  }
  if (best == null) return null;
  final ride = trip.rideTo(best.k, onBoard: onBoard);
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

/// Rule 2 of the journey list: on any bus of a journey you sit on a
/// vehicle (as when you're on a bus now), so getting off to change must
/// clearly pay. Runs on journeys as they will be shown, after the walking
/// rule.
///
/// For every bus R of a journey (run X), "stay on X to its stop nearest
/// [to], then walk at most [maxWalk]" is worked out and added to the list.
/// Then:
///  * R shown in the journey and followed by N more buses: unless the
///    journey arrives at least N × the threshold earlier ([policy], from
///    "I prefer"), it goes under "show more" ([Itinerary.hiddenFor]);
///  * R replaced by a walk (the walking rule's preferred choice, R left as
///    a swipe option) and followed by more buses in the planner's journey:
///    only the stay-on journey is added, nothing is judged (the journey
///    shown doesn't change after R).
///
/// Runs come from [runOf] (cached by the caller; the bus you're on now is
/// [riding], as the search saw it), at most [maxRuns] per call: shown buses first, earliest-arriving journeys first. Buses whose
/// run is unknown are left alone: never guess.
Future<List<Itinerary>> checkStayingOn(
  List<Itinerary> all, {
  required LatLng to,
  String toName = '',
  required Future<TripInfo> Function(String backendTripId) runOf,
  required WalkCache walks,
  required StayOnPolicy policy,
  required Duration maxWalk,
  required double walkSpeed,
  int maxRuns = 12,
  OnBoardTrip? riding,
}) async {
  // Buses replaced by a walk that the planner's journey ([Itinerary.base])
  // changed from (more buses after them): staying on them instead is worth
  // building. (Slots in [Itinerary.walkSlots] count its rides in order. A
  // walked last bus is just the planner's journey: already a swipe option.)
  List<(int, Leg)> walkedRides(Itinerary it) {
    final base = it.base;
    if (base == null || it.walkSlots.isEmpty) return const [];
    final rides = [for (var i = 0; i < base.legs.length; i++) if (base.legs[i].transit) i];
    return [
      for (var slot = 0; slot < rides.length - 1; slot++)
        if (it.walkSlots.contains(slot)) (rides[slot], base.legs[rides[slot]]),
    ];
  }

  final sorted = [...all]..sort((a, b) => a.end.compareTo(b.end));
  final runIds = <String>[];
  void want(String? id) {
    if (id != null && !runIds.contains(id) && runIds.length < maxRuns) runIds.add(id);
  }

  for (final it in sorted) {
    final rides = it.transitLegs.toList();
    for (var r = 0; r < rides.length - 1; r++) {
      want(rides[r].backendTripId);
    }
  }
  for (final it in sorted) {
    for (final (_, ride) in walkedRides(it)) {
      want(ride.backendTripId);
    }
  }
  final runs = <String, TripInfo>{};
  await Future.wait(runIds.map((id) async {
    try {
      final t = await runOf(id);
      if (t.stops.isNotEmpty) runs[id] = t;
    } catch (_) {}
  }));

  // Staying on from each boarding: shared by the journeys that board there.
  final stays = <String, Future<Itinerary?>>{};
  Future<Itinerary?> stayFrom(Leg ride) {
    final id = ride.backendTripId!;
    return stays['$id|${ride.fromStopId}|${ride.onBoard}'] ??= () async {
      final info = runs[id]!;
      final run = OnBoardRide(
        backendTripId: id,
        tripId: ride.tripId ?? id,
        line: ride.routeShortName ?? ride.mode,
        mode: ride.mode,
        headsign: ride.headsign ?? '',
      );
      // The bus you're on now is where it is; any other bus starts at its
      // boarding stop.
      final trip = ride.onBoard
          ? (riding != null && riding.isThisRun(ride) ? riding : OnBoardTrip(run, info, now: ride.start))
          : OnBoardTrip(run, info, now: ride.start, boardedAt: ride.fromStopId);
      if (trip.remaining.isEmpty) return null;
      try {
        return await stayOnBoard(trip, to, walks,
            toName: toName,
            candidates: 2,
            maxWalk: maxWalk,
            maxWalkMeters: maxWalk.inSeconds * walkSpeed,
            onBoard: ride.onBoard);
      } catch (_) {
        return null;
      }
    }();
  }

  final out = <Itinerary>[];
  final added = <String>{};
  void addStay(Itinerary stayJourney) {
    final key = [for (final l in stayJourney.transitLegs) l.backendTripId ?? l.routeShortName].join('|');
    if (added.add('$key@${stayJourney.end}')) out.add(stayJourney);
  }

  Itinerary stayJourney(Itinerary from, List<Leg> before, Itinerary stay) => Itinerary(
        start: from.start,
        end: stay.end,
        legs: [...before, ...stay.legs],
        transfers: [...before, ...stay.legs].where((l) => l.transit).length - 1,
      );

  for (final it in all) {
    // Buses replaced by a walk: only the stay-on journey, from the
    // planner's journey up to that bus.
    for (final (i, ride) in walkedRides(it)) {
      if (ride.backendTripId == null || !runs.containsKey(ride.backendTripId)) continue;
      final stay = await stayFrom(ride);
      if (stay != null) addStay(stayJourney(it.base!, it.base!.legs.sublist(0, i), stay));
    }

    // Buses shown: the stay-on journey, and the verdict.
    final legs = it.legs;
    var verdict = it;
    final rideIdx = [for (var i = 0; i < legs.length; i++) if (legs[i].transit) i];
    for (var r = 0; r < rideIdx.length - 1; r++) {
      final ride = legs[rideIdx[r]];
      if (ride.backendTripId == null || !runs.containsKey(ride.backendTripId)) continue;
      final stay = await stayFrom(ride);
      if (stay == null) continue;
      final staying = stayJourney(it, legs.sublist(0, rideIdx[r]), stay);
      addStay(staying);
      final changesSaved = rideIdx.length - 1 - r;
      final bar = policy.threshold(staying.duration) * changesSaved;
      if (it.end.isAfter(stay.end.subtract(bar))) {
        verdict = it.hiddenFor(StayOnReason(
          line: ride.routeShortName ?? ride.mode,
          arrival: stay.end,
          changesSaved: changesSaved,
        ));
        break;
      }
    }
    out.add(verdict);
  }
  return out;
}

/// The trip you're on has no stops left (it ended, or you passed them all).
class OnBoardTripOver implements Exception {
  const OnBoardTripOver();
  @override
  String toString() => 'The trip has no stops left';
}
