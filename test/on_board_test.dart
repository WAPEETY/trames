import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/route_search.dart';
import 'package:roma_transit/backend/trip_variants.dart';

final _now = DateTime(2026, 11, 14, 14, 18);
DateTime _m(num min) => _now.add(Duration(seconds: (min * 60).round()));

// The run you're on: S0 passed 2 min ago, then S1..S5 ahead, ~550 m apart.
LatLng _pos(int i) => LatLng(41.90, 12.50 - 0.0066 * i);
const _ride = OnBoardRide(backendTripId: 'run64', tripId: '64-raw', line: '64', mode: 'BUS', headsign: 'San Pietro');
final _times = [-2, 2, 5, 10, 15, 20];
TripInfo _info() => TripInfo(
      line: '64',
      mode: 'BUS',
      headsign: 'San Pietro',
      points: [for (var i = 0; i < 6; i++) _pos(i)],
      realtime: true,
      stops: [
        for (var i = 0; i < 6; i++)
          TripStop(name: 'S$i', position: _pos(i), stopId: 's$i', time: _m(_times[i]), scheduled: _m(_times[i]), live: true),
      ],
    );
OnBoardTrip _trip() => OnBoardTrip(_ride, _info(), now: _now);

Leg _walk(num a, num b, {LatLng? from, LatLng? to}) => Leg(
    mode: 'WALK', transit: false, start: _m(a), end: _m(b), fromName: '', toName: '',
    from: from ?? _pos(0), to: to ?? _pos(0), points: const [], distanceMeters: 100);
Leg _bus(String line, String trip, num a, num b, {required String from, required String to}) => Leg(
    mode: 'BUS', transit: true, start: _m(a), end: _m(b), fromName: from, toName: to,
    from: _pos(0), to: _pos(0), points: const [], distanceMeters: 0,
    routeShortName: line, tripId: '$trip-raw', backendTripId: trip, fromStopId: from, toStopId: to);
Itinerary _it(List<Leg> legs) =>
    Itinerary(start: legs.first.start, end: legs.last.end, legs: legs, transfers: legs.where((l) => l.transit).length - 1);

void main() {
  group('OnBoardTrip', () {
    test('stops ahead and where the bus is between the last two', () {
      final t = _trip();
      expect(t.remaining.map((s) => s.stopId), ['s1', 's2', 's3', 's4', 's5']);
      // 2 of the 4 minutes from S0 to S1: halfway.
      expect(t.position.longitude, closeTo((_pos(0).longitude + _pos(1).longitude) / 2, 1e-9));
    });

    test('the ride to a stop starts now, on board, on this run', () {
      final r = _trip().rideTo(2);
      expect(r.onBoard, isTrue);
      expect(r.start, _now);
      expect(r.end, _m(10));
      expect(r.toStopId, 's3');
      expect(r.fromStopId, 's1'); // live data followed at the next stop
      expect(r.tripId, '64-raw');
      expect(r.intermediateStops, 2);
    });

    test('no stops left once past the last one', () {
      expect(OnBoardTrip(_ride, _info(), now: _m(21)).remaining, isEmpty);
    });
  });

  group('onBoardOffsets', () {
    test('every stop ahead when the bus gets there; nearby stops with the walk and a margin', () {
      final near = Stop(id: 'tram8', name: 'Tram 8', position: LatLng(41.9009, _pos(2).longitude), distanceMeters: 0);
      final far = Stop(id: 'far', name: 'Far', position: const LatLng(41.95, 12.5), distanceMeters: 0);
      final o = onBoardOffsets(_trip(), [near, far], walkSpeed: 1.0);
      expect(o['s2']!.offset, const Duration(minutes: 5) + kOnBoardTransferBuffer);
      expect(o['s2']!.walk, Duration.zero);
      expect(o.containsKey('far'), isFalse);
      final t8 = o['tram8']!;
      expect(t8.index, 1); // from S2
      expect(t8.walk.inSeconds, closeTo(100 * 1.3, 2)); // ~100 m
      expect(t8.offset, const Duration(minutes: 5) + t8.walk + kOnBoardTransferBuffer);
    });
  });

  group('fromOnBoardPlan', () {
    final offsets = onBoardOffsets(_trip(), const []);

    test('get off, then the next bus: the ride replaces the fake first leg, the change counts', () {
      final raw = _it([_walk(3, 5), _bus('H', 'h1', 7, 25, from: 's2', to: 'x'), _walk(25, 28)]);
      final it = fromOnBoardPlan(raw, _trip(), offsets)!;
      expect(it.start, _now);
      expect(it.end, _m(28));
      expect(it.transfers, 1);
      expect(it.legs.first.onBoard, isTrue);
      expect(it.legs.first.toStopId, 's2');
      expect(it.legs[1].routeShortName, 'H');
      expect(staysOnBoard(it), isFalse);
    });

    test('too little time to change at the stop: dropped', () {
      final raw = _it([_walk(3, 5), _bus('H', 'h1', 5.5, 25, from: 's2', to: 'x')]);
      expect(fromOnBoardPlan(raw, _trip(), offsets), isNull);
    });

    test('staying on with a long walk is not protected as staying on', () {
      final t = _trip();
      final long = Itinerary(start: _now, end: _m(45), transfers: 0, legs: [t.rideTo(4), _walk(20, 45)]);
      expect(staysOnBoard(long), isFalse);
    });

    test('boarding the same run again is staying on', () {
      final raw = _it([_walk(0, 2), _bus('64', 'run64', 2, 15, from: 's1', to: 's4'), _walk(15, 20)]);
      final it = fromOnBoardPlan(raw, _trip(), offsets)!;
      expect(it.legs, hasLength(2));
      expect(it.legs.first.toStopId, 's4');
      expect(it.transfers, 0);
      expect(it.end, _m(20));
      expect(staysOnBoard(it), isTrue);
    });

    test('a detour that catches the same run again folds into staying on', () {
      // Get off at S1, the 60 to S3 ahead of it, back on the 64 at S3.
      final raw = _it([
        _walk(0, 2),
        _bus('60', 'b60', 3, 8, from: 's1', to: 's3'),
        _bus('64', 'run64', 10, 20, from: 's3', to: 's5'),
        _walk(20, 24),
      ]);
      final it = fromOnBoardPlan(raw, _trip(), offsets)!;
      expect(it.legs.map((l) => l.routeShortName ?? l.mode), ['64', 'WALK']);
      expect(it.legs.first.toStopId, 's5');
      expect(it.transfers, 0);
    });

    test('from a stop a walk away: ride, walk, then the next ride', () {
      final near = Stop(id: 'tram8', name: 'Tram 8', position: LatLng(41.9009, _pos(2).longitude), distanceMeters: 0);
      final o = onBoardOffsets(_trip(), [near], walkSpeed: 1.0);
      final raw = _it([_walk(4, 8), Leg(
          mode: 'TRAM', transit: true, start: _m(9), end: _m(20), fromName: 'Tram 8', toName: 'y',
          from: near.position, to: _pos(0), points: const [], distanceMeters: 0,
          routeShortName: '8', tripId: 't8', backendTripId: 't8', fromStopId: 'tram8', toStopId: 'y')]);
      final it = fromOnBoardPlan(raw, _trip(), o)!;
      expect(it.legs.map((l) => l.mode), ['BUS', 'WALK', 'TRAM']);
      expect(it.legs[1].toName, 'Tram 8');
      expect(it.legs[1].start, _m(5));
      expect(it.transfers, 1);
    });

    test('starting from a stop that is not an offset: dropped', () {
      final raw = _it([_walk(0, 2), _bus('H', 'h1', 7, 25, from: 'elsewhere', to: 'x')]);
      expect(fromOnBoardPlan(raw, _trip(), offsets), isNull);
    });
  });

  group('staying on (rule 2, on board)', () {
    final trip = _trip();
    // The destination: ~110 m from S5, where the bus is at +20 min.
    final dest = LatLng(41.901, _pos(5).longitude);
    Itinerary stay(num end) => Itinerary(
        start: _now, end: _m(end), transfers: 0, legs: [trip.rideTo(4), _walk(20, end)]);
    Itinerary change(num end, int transfers) => Itinerary(
        start: _now,
        end: _m(end),
        transfers: transfers,
        legs: [trip.rideTo(1), for (var i = 0; i < transfers; i++) _bus('X$i', 'x$i', 6, end, from: 's2', to: 'z')]);
    Future<List<Itinerary>> check(List<Itinerary> all) => checkStayingOn(
          all,
          to: dest,
          runOf: (id) async => id == 'run64' ? _info() : throw Exception('unknown run'),
          walks: WalkCache(_MeterWalks()),
          policy: kStayOnPolicy,
          maxWalk: const Duration(minutes: 12),
          walkSpeed: 1.0,
        );

    test('a change must save max(5 min, 15%) per change, else it goes under "show more"', () async {
      // Staying on: S5 at +20, then ~110 s on foot: about +21.8.
      final out = await check([change(18, 1), change(15, 1), change(13, 2), change(11, 2)]);
      final byEnd = {for (final it in out) if (it.transfers > 0) it.end: it.hiddenBecause?.line};
      expect(byEnd, {_m(18): '64', _m(15): null, _m(13): '64', _m(11): null});
    });

    test('the stay-on journey is added, on board', () async {
      final out = await check([change(18, 1)]);
      final stayOn = out.where(staysOnBoard).single;
      expect(stayOn.legs.first.onBoard, isTrue);
      expect(stayOn.legs.first.toStopId, 's5');
      expect(stayOn.hiddenBecause, isNull);
    });

    test('a run whose stops are unknown: nothing is hidden', () async {
      final out = await checkStayingOn(
        [change(18, 1)],
        to: dest,
        runOf: (_) async => throw Exception('offline'),
        walks: WalkCache(_MeterWalks()),
        policy: kStayOnPolicy,
        maxWalk: const Duration(minutes: 12),
        walkSpeed: 1.0,
      );
      expect(out.single.hiddenBecause, isNull);
    });

    test('the bar grows with the time left', () {
      expect(kStayOnPolicy.threshold(const Duration(minutes: 20)), const Duration(minutes: 5));
      expect(kStayOnPolicy.threshold(const Duration(minutes: 60)), const Duration(minutes: 9));
    });

    test('staying on is listed first, even when a change is faster', () {
      final groups = RouteSearch(_NoPlanner(), clock: () => _now).group([change(22, 1), stay(30)]);
      expect(staysOnBoard(groups.first.best), isTrue);
      expect(groups.first.tags, contains(RouteTag.stayOnBoard));
      expect(groups[1].tags, contains(RouteTag.fastest));
    });

    test('kept in the list after it started (you are already on it)', () {
      final groups = RouteSearch(_NoPlanner(), clock: () => _m(3)).group([stay(30)]);
      expect(groups, hasLength(1));
    });
  });

  test('the ride you are on is never swapped, walked or hidden', () {
    final trip = _trip();
    // Getting off at the very next stop: a ride shorter than the hide limit.
    final it = Itinerary(
        start: _now, end: _m(25), transfers: 1,
        legs: [trip.rideTo(0), _bus('H', 'h1', 4, 20, from: 's1', to: 'x'), _walk(20, 25)]);
    final tv = TripVariants(it, walks: WalkCache(_NoWalks()), clock: () => _now);
    expect(tv.hasHidden, isFalse);
    expect(tv.walkIndex(0), isNull);
    expect(tv.variantCount(0), 1);
  });
}

class _NoPlanner implements TripPlanner {
  @override
  Future<List<Itinerary>> plan(LatLng from, LatLng to, {PlanOptions options = const PlanOptions()}) async => const [];
}

class _NoWalks implements WalkRouter {
  @override
  Future<WalkRoute?> walk(LatLng from, LatLng to) async => null;
}

/// Walks at 1 m/s along the straight line.
class _MeterWalks implements WalkRouter {
  @override
  Future<WalkRoute?> walk(LatLng from, LatLng to) async {
    final m = distanceMeters(from, to);
    return WalkRoute(duration: Duration(seconds: m.round()), distanceMeters: m, points: [from, to]);
  }
}
