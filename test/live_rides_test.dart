import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/live_rides.dart';
import 'package:roma_transit/backend/trip_variants.dart';
import 'package:roma_transit/backend/walk_rules.dart';

final _t0 = DateTime(2026, 11, 13, 8);
DateTime _m(int min) => _t0.add(Duration(minutes: min));
const _p = LatLng(41.9, 12.5);

Leg _walk(int a, int b) => Leg(
    mode: 'WALK', transit: false, start: _m(a), end: _m(b), fromName: '', toName: '',
    from: _p, to: _p, points: const [], distanceMeters: 100);
Leg _ride(String line, String trip, int a, int b, {List<LegAlternative> alts = const []}) => Leg(
    mode: 'BUS', transit: true, start: _m(a), end: _m(b), fromName: '', toName: '',
    from: _p, to: _p, points: const [], distanceMeters: 0, routeShortName: line, tripId: trip, alternatives: alts);

// walk 0-4, 88 4-10, walk 10-12, 60 15-40, walk 40-43
Itinerary _trip({List<LegAlternative> second = const []}) => Itinerary(
      start: _m(0),
      end: _m(43),
      transfers: 1,
      legs: [_walk(0, 4), _ride('88', 'a', 4, 10), _walk(10, 12), _ride('60', 'b', 15, 40, alts: second), _walk(40, 43)],
    );

/// Live times by trip: minutes after [_t0], or null for a bus that is gone.
LiveRide? Function(Leg) _live(Map<String, int?> at) => (l) => !at.containsKey(l.tripId)
    ? null
    : switch (at[l.tripId]) { final int m => LiveRide(start: _m(m)), null => const LiveRide(gone: true) };

/// A trip A -> B -> A -> C (it calls at A twice), by minutes after [_t0]:
/// timetable 4, 10, 30, 40, running [late] minutes behind.
TramiteTrip _tripOf({int late = 0, bool realtime = true, bool inferred = false, int? busSeq, bool cancelled = false}) {
  TramiteTripStop stop(String id, int seq, int min) => TramiteTripStop(
      stopId: id, name: id, position: _p, sequence: seq,
      scheduledArrival: _m(min), arrival: _m(min + late),
      scheduledDeparture: _m(min), departure: _m(min + late),
      realtime: realtime, inferred: inferred, cancelled: false);
  return TramiteTrip(
      tripId: 'a', backendTripId: 'a', line: '88', cancelled: cancelled, busSequence: busSeq, started: busSeq != null,
      stops: [stop('A', 1, 4), stop('B', 2, 10), stop('A', 3, 30), stop('C', 4, 40)]);
}

Leg _from(String from, String to, int a, int b, {bool realtime = false, int? delay}) => Leg(
    mode: 'BUS', transit: true, start: _m(a), end: _m(b), fromName: '', toName: '', from: _p, to: _p,
    points: const [], distanceMeters: 0, tripId: 'a', fromStopId: from, toStopId: to,
    realtime: realtime, delaySeconds: delay, arrivalDelaySeconds: delay);

class _Walk20 implements WalkRouter {
  @override
  Future<WalkRoute?> walk(LatLng from, LatLng to) async =>
      WalkRoute(duration: const Duration(minutes: 20), distanceMeters: 1500, points: [from, to]);
}

void main() {
  Itinerary apply(Itinerary it, Map<String, int?> at) => applyLiveTimes(it, _live(at), clock: () => _t0);
  String rides(Itinerary it) => it.transitLegs.map((l) => '${l.routeShortName}@${l.start.difference(_t0).inMinutes}').join(' ');

  test('no live time, or the planner\'s own: unchanged', () {
    final it = _trip();
    expect(apply(it, {}), same(it));
    expect(apply(it, {'a': 4, 'b': 15}), same(it));
  });

  test('late first ride that still connects: leave later, same arrival', () {
    final r = apply(_trip(), {'a': 7});
    expect(rides(r), '88@7 60@15');
    expect(r.start, _m(3));
    expect(r.end, _m(43));
    expect(r.missedConnection, isFalse);
  });

  test('connection broken: the next bus that works is taken', () {
    final later60 = LegAlternative([_walk(10, 12), _ride('60', 'c', 25, 50), _walk(50, 53)]);
    final r = apply(_trip(second: [later60]), {'a': 12}); // 88 arrives 18, walk to 20 > 15
    expect(rides(r), '88@12 60@25');
    expect(r.end, _m(53));
    expect(r.missedConnection, isFalse);
    // The trip view reopens on the same buses.
    final again = TripVariants(r.base!, choices: r.rideChoices, clock: () => _t0).current;
    expect(rides(again), '88@12 60@25');
  });

  test('no bus makes the connection: flagged', () {
    final r = apply(_trip(), {'a': 12});
    expect(r.missedConnection, isTrue);
    expect(rides(r), '88@12 60@15');
  });

  test('no bus makes it and the walk is longer than the user accepts: flagged, not walked', () async {
    final walks = WalkCache(_Walk20());
    await walks.fetch([(_p, _p)]);
    Itinerary at(Duration? cap) => applyLiveTimes(_trip(), _live({'a': 12}),
        walks: walks, clock: () => _t0, policy: WalkPolicy(maxRideWalk: cap));
    final free = at(null); // any walk: the 60 is walked, 20 minutes
    expect(rides(free), '88@12');
    expect(free.missedConnection, isFalse);
    final some = at(const Duration(minutes: 12));
    expect(rides(some), '88@12 60@15');
    expect(some.missedConnection, isTrue);
  });

  test('late last ride: arrival moves', () {
    final r = apply(_trip(), {'b': 21});
    expect(rides(r), '88@4 60@21');
    expect(r.end, _m(49));
  });

  test('applied again with a new time: from the planner\'s time, not on top', () {
    final once = apply(_trip(), {'a': 7});
    final twice = apply(once, {'a': 6});
    expect(rides(twice), '88@6 60@15');
    expect(apply(twice, {'a': 6}), same(twice));
    // No live time any more: back to the planner's.
    expect(rides(apply(twice, {})), '88@4 60@15');
  });

  test('early second ride you would miss: its next bus', () {
    final later60 = LegAlternative([_walk(10, 12), _ride('60', 'c', 25, 50), _walk(50, 53)]);
    final r = apply(_trip(second: [later60]), {'b': 11}); // you are at its stop at 12
    expect(rides(r), '88@4 60@25');
    expect(r.missedConnection, isFalse);
  });

  test('first bus gone: its next bus, else flagged and dropped from the list', () {
    final later88 = LegAlternative([_walk(4, 8), _ride('88', 'd', 8, 13), _walk(13, 15)]);
    final it = Itinerary(start: _m(0), end: _m(43), transfers: 1, legs: [
      _walk(0, 4),
      _ride('88', 'a', 4, 10, alts: [later88]),
      _walk(10, 12),
      _ride('60', 'b', 15, 40),
      _walk(40, 43),
    ]);
    final r = apply(it, {'a': null});
    expect(rides(r), '88@8 60@15');
    expect(firstRideGone(r, _live({'a': null})), isFalse);

    final none = apply(_trip(), {'a': null});
    expect(none.missedConnection, isTrue);
    expect(firstRideGone(none, _live({'a': null})), isTrue);
  });

  group('an earlier bus that runs late', () {
    // Now is minute 20. Planned: walk 36-37, 66 37-60, walk 60-62, 3NAV 66-73,
    // walk 73-74. The 66 before it was due at 9: left, by the timetable.
    final now = _m(20);
    LegAlternative early66() => LegAlternative([_walk(8, 9), _ride('66', 'e', 9, 32), _walk(32, 34)]);
    LegAlternative later66() => LegAlternative([_walk(39, 40), _ride('66', 'l', 40, 63), _walk(63, 65)]);
    Itinerary trip({List<LegAlternative> first = const [], List<LegAlternative> second = const []}) => Itinerary(
          start: _m(36),
          end: _m(74),
          transfers: 1,
          legs: [
            _walk(36, 37),
            _ride('66', 'n', 37, 60, alts: first),
            _walk(60, 62),
            _ride('3NAV', 'x', 66, 73, alts: second),
            _walk(73, 74),
          ],
        );
    Itinerary list(Itinerary it, Map<String, int?> at) =>
        applyLiveTimes(it, _live(at), clock: () => now, earlier: true);
    LegAlternative bus19(int a) => LegAlternative([_walk(a - 4, a - 2), _ride('19BUS', 'y', a, a + 8), _walk(a + 8, a + 9)]);

    test('no live time for it: gone, the journey stands', () {
      final it = trip(first: [early66()]);
      expect(list(it, {}), same(it));
    });

    test('still to come: taken, and the next ride moves earlier too', () {
      final r = list(trip(first: [early66()], second: [bus19(50)]), {'e': 21});
      expect(rides(r), '66@21 19BUS@50');
      expect(r.start, _m(20));
      expect(r.end, _m(59));
      expect(r.missedConnection, isFalse);
      // The journey view reopens on the same buses.
      final again = TripVariants(r.base!, choices: r.rideChoices, clock: () => now).current;
      expect(rides(again), '66@21 19BUS@50');
    });

    test('same arrival: taken when you leave up to the policy\'s wait sooner', () {
      expect(rides(list(trip(first: [early66()]), {'e': 21})), '66@21 3NAV@66'); // leaves 20, 16 sooner
      Itinerary strict(Map<String, int?> at) => applyLiveTimes(trip(first: [early66()]), _live(at),
          clock: () => now, earlier: true, policy: const WalkPolicy(earlierRideWait: Duration(minutes: 10)));
      expect(rides(strict({'e': 29})), '66@29 3NAV@66'); // 8 sooner
      expect(rides(strict({'e': 21})), '66@37 3NAV@66'); // 16 sooner: leave later
    });

    test('another line doing the same stretch: taken too', () {
      final early60 = LegAlternative([_walk(8, 9), _ride('60', 'e', 9, 32), _walk(32, 34)]);
      final r = list(trip(first: [early60], second: [bus19(50)]), {'e': 21});
      expect(rides(r), '60@21 19BUS@50');
      expect(r.end, _m(59));
    });

    test('an earlier bus on time, same arrival: taken (the planner would leave later)', () {
      final onTime = LegAlternative([_walk(24, 25), _ride('66', 'e', 25, 48), _walk(48, 50)]);
      final r = list(trip(first: [onTime]), {});
      expect(rides(r), '66@25 3NAV@66');
      expect(r.start, _m(24));
      expect(r.end, _m(74));
      // And the next ride moves earlier when one fits.
      expect(rides(list(trip(first: [onTime], second: [bus19(52)]), {})), '66@25 19BUS@52');
    });

    test('it has gone by: not taken', () {
      expect(rides(list(trip(first: [early66()]), {'e': null})), '66@37 3NAV@66');
    });

    test('an open journey keeps its rides', () {
      final it = trip(first: [early66()], second: [bus19(50)]);
      expect(rides(applyLiveTimes(it, _live({'e': 21}), clock: () => now)), '66@37 3NAV@66');
      // The later 66 was picked before the late one could be caught: still it.
      final v = TripVariants(trip(first: [early66(), later66()]), clock: () => now);
      v.choose(0, 1);
      expect(rides(v.current), '66@40 3NAV@66');
      final r = applyLiveTimes(v.current, _live({'e': 21}), clock: () => now);
      expect(rides(r), '66@40 3NAV@66');
    });
  });

  group('the surest buses', () {
    // Now is minute 0. Planned: walk 9-10, 66 'g' 10-30 (timetable), walk
    // 30-32, 88 'h' 40-50, walk 50-51.
    LegAlternative alt(String line, String trip, int a) =>
        LegAlternative([_walk(a - 1, a), _ride(line, trip, a, a + 20), _walk(a + 20, a + 22)]);
    Itinerary trip(List<LegAlternative> first) => Itinerary(
          start: _m(9),
          end: _m(51),
          transfers: 1,
          legs: [_walk(9, 10), _ride('66', 'g', 10, 30, alts: first), _walk(30, 32), _ride('88', 'h', 40, 50), _walk(50, 51)],
        );
    // Sureness by trip: 2 live, 1 estimated, else timetable.
    Itinerary pick(Itinerary it, Map<String, int> sure, {bool surest = true, bool earlier = true}) => applyLiveTimes(
        it, (_) => null,
        clock: () => _t0, earlier: earlier, surest: surest, sureness: (l) => sure[l.tripId] ?? 0);

    test('a live bus of the line a little later: taken over the timetable one', () {
      final it = trip([alt('66', 'live', 14)]);
      expect(rides(pick(it, {'live': 2})), '66@14 88@40');
      // The planner's own version keeps its bus: both get listed.
      expect(pick(it, {'live': 2}, surest: false), same(it));
    });

    test('live over estimated over timetable, whatever the line', () {
      final it = trip([alt('60', 'est', 12), alt('60', 'live', 16)]);
      expect(rides(pick(it, {'est': 1, 'live': 2})), '60@16 88@40');
      expect(rides(pick(it, {'est': 1})), '60@12 88@40');
    });

    test('nothing surer, or the surer bus breaks the connection: unchanged', () {
      final it = trip([alt('66', 'x', 14)]);
      expect(pick(it, {}), same(it));
      final late = trip([alt('66', 'live', 25)]); // arrives 45, the 88 leaves at 40
      expect(pick(late, {'live': 2}), same(late));
    });

    test('walking is never the surer choice', () async {
      final walks = WalkCache(_Walk20());
      await walks.fetch([(_p, _p)]);
      final it = trip(const []);
      expect(applyLiveTimes(it, (_) => null, walks: walks, clock: () => _t0, surest: true, earlier: true, sureness: (_) => 0),
          same(it));
    });

    test('the earlier-bus rule never moves onto a less sure bus', () {
      // Planned on the live 66 at 10; a timetable 66 at 5 gets there no later.
      final it = trip([alt('66', 'grey', 5)]);
      expect(pick(it, {'g': 2, 'h': 2}, surest: false), same(it));
      // As sure as the planned one: taken.
      expect(rides(pick(it, {'g': 2, 'h': 2, 'grey': 2}, surest: false)), '66@5 88@40');
    });
  });

  group('liveJourneys', () {
    // Now is minute 0. Journey A: 60 'a1' 10-30, walk, 19 'b1' 35-45.
    // Journey B: 60 'a2' 30-50, walk, 19 'b2' 55-65; the 60 'a1' is an
    // alternative of its first ride.
    Itinerary two(String t1, int a, String t2, int b, {List<LegAlternative> first = const []}) => Itinerary(
          start: _m(a - 1),
          end: _m(b + 11),
          transfers: 1,
          legs: [
            _walk(a - 1, a),
            _ride('60', t1, a, a + 20, alts: first),
            _walk(a + 20, a + 22),
            _ride('19', t2, b, b + 10),
            _walk(b + 10, b + 11),
          ],
        );
    final early60 = LegAlternative([_walk(9, 10), _ride('60', 'a1', 10, 30), _walk(30, 32)]);
    List<String> list(List<Itinerary> its) => [
          for (final it in liveJourneys(its, (_) => null, clock: () => _t0)) '${rides(it)} ${it.end.difference(_t0).inMinutes}',
        ];

    test('leaving earlier for the same arrival: only when no journey from then arrives sooner', () {
      final b = two('a2', 30, 'b2', 55, first: [early60]);
      // Alone: the earlier 60 is taken (20 minutes sooner, same arrival).
      expect(list([b]), ['60@10 19@55 66']);
      // With journey A (same 60, arrives at 46): B keeps its later departure.
      expect(list([two('a1', 10, 'b1', 35), b]), ['60@10 19@35 46', '60@30 19@55 66']);
    });
  });

  group('liveRideFor', () {
    final ride = _from('A', 'B', 4, 10);
    final live88 = _from('A', 'B', 6, 12, realtime: true, delay: 120);

    test('Tramite live: its times at both stops, also over the planner\'s live times', () {
      final r = liveRideFor(ride, _tripOf(late: 17))!;
      expect((r.start, r.end), (_m(21), _m(27)));
      expect(liveRideFor(live88, _tripOf(late: 5))!.start, _m(9));
    });
    test('Tramite timetable only: the planner\'s times stand', () {
      expect(liveRideFor(ride, _tripOf(realtime: false)), isNull);
      expect(liveRideFor(live88, _tripOf(realtime: false)), isNull);
      expect(liveRideFor(ride, null), isNull);
    });
    test('inferred: only when the planner has no live time', () {
      expect(liveRideFor(ride, _tripOf(late: 5, realtime: false, inferred: true))!.end, _m(15));
      expect(liveRideFor(live88, _tripOf(late: 5, realtime: false, inferred: true)), isNull);
    });
    test('bus past the boarding stop, or trip cancelled: gone', () {
      expect(liveRideFor(ride, _tripOf(busSeq: 2))!.gone, isTrue);
      expect(liveRideFor(ride, _tripOf(late: 2, busSeq: 1))!.gone, isFalse);
      expect(liveRideFor(ride, _tripOf(cancelled: true))!.gone, isTrue);
    });
    test('a stop the trip calls at twice: the visit the planner means', () {
      // Boarding at A the second time (30), the bus now heading to B.
      final r = liveRideFor(_from('A', 'C', 30, 40), _tripOf(late: 6, busSeq: 2))!;
      expect(r.gone, isFalse);
      expect((r.start, r.end), (_m(36), _m(46)));
      // Getting off at A: the visit after boarding, not the first stop.
      expect(liveRideFor(_from('B', 'A', 10, 30), _tripOf(late: 6))!.end, _m(36));
    });
    test('a time on the wrong day is a feed error: not used', () {
      expect(liveRideFor(ride, _tripOf(late: 24 * 60 + 5)), isNull);
    });
    test('another run of the line (timetable far from the planner\'s) is ignored', () {
      expect(liveRideFor(_from('B', 'C', 25, 55), _tripOf(late: 6)), isNull);
    });
  });

  test('a ride arriving later than it leaves late: both times kept, and undone', () {
    final leg = _ride('88', 'a', 4, 10);
    final live = leg.at(_m(7), _m(16));
    expect((live.start, live.end, live.planned, live.plannedArrival), (_m(7), _m(16), _m(4), _m(10)));
    expect(live.at(_m(5)).end, _m(11), reason: 'no live arrival: as late as it leaves');
    final back = live.at(null);
    expect((back.start, back.end), (_m(4), _m(10)));
  });
}
