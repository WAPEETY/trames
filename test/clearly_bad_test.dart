import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/route_search.dart';

// Journeys that make no sense (rule 1: swaps; rule 2: getting off a bus
// that already takes you there), on the Largo Somalia -> Via Jacopone da
// Todi case.

final _t0 = DateTime.now().add(const Duration(minutes: 5));
DateTime _m(num min) => _t0.add(Duration(seconds: (min * 60).round()));

// The 63 run: S0 (Largo Somalia) ... S5, 5 min apart, ~415 m apart.
LatLng _s(int i) => LatLng(41.92, 12.52 - 0.005 * i);
final _dest = LatLng(41.921, _s(5).longitude); // ~110 m from S5
const _elsewhere = LatLng(41.95, 12.40);

Leg _walk(num a, num b, {LatLng? from, LatLng? to}) => Leg(
    mode: 'WALK', transit: false, start: _m(a), end: _m(b), fromName: '', toName: '',
    from: from ?? _s(0), to: to ?? _s(0), points: const [], distanceMeters: 100);
Leg _ride(String line, String run, num a, num b,
        {required LatLng from, required LatLng to, String? fromStop, String? toStop, List<LegAlternative> alts = const []}) =>
    Leg(
        mode: 'BUS', transit: true, start: _m(a), end: _m(b), fromName: '', toName: '', from: from, to: to,
        points: const [], distanceMeters: 0, routeShortName: line, tripId: run, backendTripId: run,
        fromStopId: fromStop, toStopId: toStop, alternatives: alts);
Itinerary _it(List<Leg> legs) =>
    Itinerary(start: legs.first.start, end: legs.last.end, legs: legs, transfers: legs.where((l) => l.transit).length - 1);

TripInfo _run63() => TripInfo(
      line: '63',
      mode: 'BUS',
      headsign: 'Rossellini',
      points: [for (var i = 0; i < 6; i++) _s(i)],
      realtime: true,
      stops: [for (var i = 0; i < 6; i++) TripStop(name: 'S$i', position: _s(i), stopId: 's$i', time: _m(5 * i), live: true)],
    );

class _NoPlanner implements TripPlanner {
  @override
  Future<List<Itinerary>> plan(LatLng from, LatLng to, {PlanOptions options = const PlanOptions()}) async => const [];
}

class _MeterWalks implements WalkRouter {
  @override
  Future<WalkRoute?> walk(LatLng from, LatLng to) async {
    final m = distanceMeters(from, to);
    return WalkRoute(duration: Duration(seconds: m.round()), distanceMeters: m, points: [from, to]);
  }
}

class _Runs implements TripDetails {
  @override
  Future<TripInfo> trip(String id) async => id == 'r63' ? _run63() : throw Exception('unknown run');
  @override
  Future<String?> sameRun(String tripId, {required String stopId, required DateTime at, String? line}) async => null;
}

void main() {
  group('rule 1: the same line again after a ride on it', () {
    final search = RouteSearch(_NoPlanner());
    // 63 from S0 to S2, then the 337 to the destination, "or a later 63".
    final later63 = LegAlternative([_ride('63', 'r63b', 12, 30, from: _s(2), to: _s(5))]);
    final other = LegAlternative([_ride('311', 'r311', 12, 28, from: _s(2), to: _s(5))]);
    final journey = _it([
      _ride('63', 'r63', 0, 10, from: _s(0), to: _s(2)),
      _ride('337', 'r337', 11, 21, from: _s(2), to: _s(5), alts: [later63, other]),
    ]);
    List<String> altsOf(Itinerary it, List<Leg> rides) =>
        search.trimAlternatives(it, rides: rides).legs[1].alternatives.map((a) => a.line).toList();

    test('dropped when a direct 63 goes from the first stop to the destination', () {
      final direct = _ride('63', 'r63', 0, 25, from: _s(0), to: _s(5));
      expect(altsOf(journey, [direct, ...journey.transitLegs]), ['311']);
    });

    test('kept when no 63 goes there directly (e.g. the first 63 ends at S2)', () {
      expect(altsOf(journey, journey.transitLegs.toList()), ['63', '311']);
    });
  });

  group('rule 2: getting off a bus that already takes you there', () {
    Future<List<Itinerary>> check(List<Itinerary> all, {StayOnPolicy policy = const StayOnPolicy(share: 0.25)}) =>
        checkStayingOn(all,
            to: _dest,
            runOf: _Runs().trip,
            walks: WalkCache(_MeterWalks()),
            policy: policy,
            maxWalk: const Duration(minutes: 12),
            walkSpeed: 1.0);

    // 63 from S0, off at S2, 311, 66: two changes.
    Itinerary threeBuses(num end) => _it([
          _walk(-2, 0),
          _ride('63', 'r63', 0, 10, from: _s(0), to: _s(2), fromStop: 's0', toStop: 's2'),
          _ride('311', 'r311', 11, end - 5, from: _s(2), to: _elsewhere),
          _ride('66', 'r66', end - 4, end - 1, from: _elsewhere, to: _dest),
          _walk(end - 1, end, from: _dest, to: _dest),
        ]);

    test('63 › 311 › 66 barely sooner than staying on the 63: under "show more"', () async {
      // Staying on: S5 at 25, ~110 s on foot -> ~26.8; 2 changes x max(5, 25%) needed.
      final out = await check([threeBuses(24)]);
      final hidden = out.firstWhere((it) => it.transfers == 2);
      expect(hidden.hiddenBecause?.line, '63');
      expect(hidden.hiddenBecause?.changesSaved, 2);
      final stay = out.firstWhere((it) => it.transfers == 0);
      expect(stay.transitLegs.single.routeShortName, '63');
      expect(stay.transitLegs.single.toStopId, 's5');
      expect(stay.hiddenBecause, isNull);
    });

    test('kept when the changes save enough', () async {
      final out = await check([threeBuses(12)]);
      expect(out.firstWhere((it) => it.transfers == 2).hiddenBecause, isNull);
    });

    test('rides on runs that cannot be looked up are left alone', () async {
      final unknown = _it([
        _ride('60', 'r60', 0, 10, from: _s(0), to: _s(2), fromStop: 's0'),
        _ride('311', 'r311', 11, 20, from: _s(2), to: _dest),
      ]);
      final out = await check([unknown]);
      expect(out.single.hiddenBecause, isNull);
    });

    test('hidden journeys are grouped apart and never tagged', () async {
      final out = await check([threeBuses(24)]);
      final groups = RouteSearch(_NoPlanner()).group(out);
      final hidden = groups.where((g) => g.hiddenBecause != null).single;
      expect(hidden.tags, isEmpty);
      expect(groups.where((g) => g.hiddenBecause == null).single.tags, contains(RouteTag.fastest));
    });
  });

  test('every journey with the fewest changes gets the tag, not just one', () {
    LatLng p = _s(0);
    final fastest = _it([_ride('211', 'a', 2, 10, from: p, to: p), _ride('MEB', 'b', 11, 20, from: p, to: p)]);
    final direct1 = _it([_walk(0, 3), _ride('63', 'c', 3, 24, from: p, to: p)]);
    final direct2 = _it([_walk(0, 1), _ride('66', 'd', 1, 26, from: p, to: p)]);
    final groups = RouteSearch(_NoPlanner()).group([fastest, direct1, direct2]);
    final tagged = groups.where((g) => g.tags.contains(RouteTag.fewestChanges)).map((g) => g.signature);
    expect(tagged, unorderedEquals(['63', '66']));
  });
}
