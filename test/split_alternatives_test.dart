import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/route_search.dart';
import 'package:roma_transit/backend/trip_variants.dart';

// Now 08:00; minutes after it.
final _t0 = DateTime(2026, 11, 24, 8);
DateTime _m(int min) => _t0.add(Duration(minutes: min));

const _home = LatLng(41.8992, 12.5177);
const _reti = LatLng(41.9010, 12.5180); // the 19L's stop
const _verano = LatLng(41.9010, 12.5223); // ~360 m from Reti: the 88's
const _change = LatLng(41.9140, 12.5130); // where the 60 leaves
const _end = LatLng(41.9418, 12.5543);

Leg _walk(LatLng f, LatLng t, int a, int b) => Leg(
    mode: 'WALK', transit: false, start: _m(a), end: _m(b), fromName: '', toName: '',
    from: f, to: t, points: [f, t], distanceMeters: 100);
Leg _ride(String line, String trip, LatLng f, LatLng t, int a, int b, {List<LegAlternative> alts = const []}) => Leg(
    mode: 'BUS', transit: true, start: _m(a), end: _m(b), fromName: line, toName: line,
    from: f, to: t, points: [f, t], distanceMeters: 0, routeShortName: line, tripId: trip, alternatives: alts);

/// The 88 from Verano at [a]: walk there, ride to the 60's stop.
LegAlternative _bus88(int a) =>
    LegAlternative([_walk(_home, _verano, a - 7, a), _ride('88', '88@$a', _verano, _change, a, a + 7), _walk(_change, _change, a + 7, a + 7)]);

/// walk 52-53, 19L 53-64 (Reti), walk 64-66, 60 68-91, walk 91-102.
Itinerary _trip(List<LegAlternative> alts) => Itinerary(start: _m(52), end: _m(102), transfers: 1, legs: [
      _walk(_home, _reti, 52, 53),
      _ride('19L', 'a', _reti, _change, 53, 64, alts: alts),
      _walk(_change, _change, 64, 66),
      _ride('60', 'b', _change, _end, 68, 91),
      _walk(_end, _end, 91, 102),
    ]);

class _NoPlanner implements TripPlanner {
  @override
  Future<List<Itinerary>> plan(LatLng from, LatLng to, {PlanOptions options = const PlanOptions()}) async => const [];
}

String _rides(Itinerary it) => it.transitLegs.map((l) => '${l.routeShortName}@${l.start.difference(_t0).inMinutes}').join(' ');

void main() {
  final search = RouteSearch(_NoPlanner(), clock: () => _t0);
  final alts = [_bus88(55), _bus88(49), _bus88(39), _bus88(23)];

  test('buses boarding too far to be alternatives are not dropped: they make a journey', () {
    final it = _trip(alts);
    expect(search.trimAlternatives(it).legs[1].alternatives, isEmpty); // not the 19L's alternatives
    final split = search.splitFarAlternatives(it);
    expect(split, hasLength(1)); // one stop, one journey
    final j = split.single;
    // Same arrival for all (the same 60): the one leaving latest.
    expect(_rides(j), '88@55 60@68');
    expect(j.start, _m(48));
    expect(j.end, _m(102));
    // The other 88s are its alternatives, by departure when swiped.
    final v = TripVariants(j, clock: () => _t0);
    expect([for (var k = 0; k < v.variantCount(0); k++) v.rideOf(0, k).start], [_m(23), _m(39), _m(49), _m(55)]);
    expect(v.choiceOf(0), 3);
  });

  test('planning for later: its ride is one you need not leave sooner for, if any', () {
    final at50 = search.splitFarAlternatives(_trip(alts), when: PlanTime(time: _m(50)));
    expect(_rides(at50.single), '88@55 60@68');
    // All before the time chosen: still a journey (not thrown away), the latest.
    final at60 = search.splitFarAlternatives(_trip([_bus88(49), _bus88(39)]), when: PlanTime(time: _m(60)));
    expect(_rides(at60.single), '88@49 60@68');
  });

  test('buses already gone are left out', () {
    // Now 08:40: the 88s at 23 and 39 have left (you'd be out at 16 and 32).
    final later = RouteSearch(_NoPlanner(), clock: () => _m(40));
    final j = later.splitFarAlternatives(_trip(alts)).single;
    expect(_rides(j), '88@55 60@68');
    expect(j.legs[1].alternatives.map((a) => a.ride.start), [_m(49)]);
  });

  test('near alternatives stay alternatives, nothing extra', () {
    final near = LegAlternative([_walk(_home, _reti, 39, 40), _ride('3', 'c', _reti, _change, 40, 51), _walk(_change, _change, 51, 51)]);
    expect(search.splitFarAlternatives(_trip([near])), isEmpty);
  });

  test('"Leaving a bit earlier" only on a row with no bus after the time chosen', () async {
    Future<List<RouteGroup>> at(int min, List<LegAlternative> a) => RouteSearch(_OnePlanner([_trip(a)]),
            profiles: const [PlanProfile('default', PlanOptions())], clock: () => _t0)
        .search(_home, _end, when: PlanTime(time: _m(min)));
    RouteGroup row88(List<RouteGroup> gs) => gs.firstWhere((g) => g.signature == '88 › 60');
    // The 88 at 55 needs you out at 48: after 08:45, so no chip.
    expect(row88(await at(45, alts)).tags, isNot(contains(RouteTag.leaveEarlier)));
    // Only 88s you'd leave before 08:50 for: the chip.
    expect(row88(await at(50, [_bus88(49), _bus88(39)])).tags, contains(RouteTag.leaveEarlier));
  });

  test('its other rides get the same trimming as every journey', () async {
    // A 61 boarding far from the 60's stop is no alternative to the 60.
    final far61 = LegAlternative([_walk(_change, _verano, 66, 72), _ride('61', 'x', _verano, _end, 72, 95), _walk(_end, _end, 95, 95)]);
    final trip = _trip(alts);
    final withFar = trip.withLegs([...trip.legs.take(3), trip.legs[3].withAlternatives([far61]), trip.legs[4]]);
    final groups = await RouteSearch(_OnePlanner([withFar]),
            profiles: const [PlanProfile('default', PlanOptions())], clock: () => _t0)
        .search(_home, _end);
    final row = groups.firstWhere((g) => g.signature == '88 › 60').best;
    expect(row.transitLegs.last.alternatives, isEmpty);
  });

  test('last ride: an alternative getting off elsewhere stays (it walks you home)', () {
    const terminus = LatLng(41.9450, 12.5600); // ~600 m from _end
    final to60 = LegAlternative([_walk(_change, _change, 72, 73), _ride('60', 'late', _change, terminus, 73, 101), _walk(terminus, _end, 101, 108)]);
    final trip = _trip(const []);
    final it = trip.withLegs([...trip.legs.take(3), trip.legs[3].withAlternatives([to60]), trip.legs[4]]);
    expect(search.trimAlternatives(it).legs[3].alternatives.single.ride.tripId, 'late');
  });

  test('at a change: an alternative getting off elsewhere is still left out', () {
    final elsewhere = LegAlternative([_walk(_home, _reti, 44, 45), _ride('3', 'c', _reti, _verano, 45, 50), _walk(_verano, _change, 50, 60)]);
    expect(search.trimAlternatives(_trip([elsewhere])).legs[1].alternatives, isEmpty);
  });

  test('the same journey from two profiles: one, with every alternative either found', () {
    final a = _trip([_bus88(55)]);
    final b = _trip([_bus88(49)]);
    final merged = RouteSearch.mergeSameJourneys([a, b]);
    expect(merged, hasLength(1));
    expect(merged.single.legs[1].alternatives.map((x) => x.ride.start), [_m(55), _m(49)]);
    // Different buses: still two journeys.
    final other = _trip(const []).withLegs([..._trip(const []).legs.take(3), _ride('61', 'z', _change, _end, 68, 91), _trip(const []).legs.last]);
    expect(RouteSearch.mergeSameJourneys([a, other]), hasLength(2));
  });

  test('in the list: a row of its own next to the 19L one', () async {
    final groups = await RouteSearch(_OnePlanner([_trip(alts)]),
            profiles: const [PlanProfile('default', PlanOptions())], clock: () => _t0)
        .search(_home, _end);
    expect(groups.map((g) => g.signature).toSet(), {'19L › 60', '88 › 60'});
  });
}

class _OnePlanner implements TripPlanner {
  _OnePlanner(this.result);
  final List<Itinerary> result;
  @override
  Future<List<Itinerary>> plan(LatLng from, LatLng to, {PlanOptions options = const PlanOptions()}) async => result;
}
