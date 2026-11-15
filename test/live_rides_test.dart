import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/live_rides.dart';
import 'package:roma_transit/backend/models.dart';
import 'package:roma_transit/backend/tramite.dart';
import 'package:roma_transit/backend/trip_variants.dart';

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
