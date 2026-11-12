import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/route_search.dart';

final _t0 = DateTime.now().add(const Duration(minutes: 5));
DateTime _m(int min) => _t0.add(Duration(minutes: min));
const _p = LatLng(41.9, 12.5);

Leg _walk(int a, int b) => Leg(
    mode: 'WALK', transit: false, start: _m(a), end: _m(b), fromName: '', toName: '',
    from: _p, to: _p, points: const [], distanceMeters: 100);
Leg _ride(String line, String trip, int a, int b) => Leg(
    mode: 'BUS', transit: true, start: _m(a), end: _m(b), fromName: '', toName: '',
    from: _p, to: _p, points: const [], distanceMeters: 0, routeShortName: line, tripId: trip);
Itinerary _it(List<Leg> legs) =>
    Itinerary(start: legs.first.start, end: legs.last.end, legs: legs, transfers: legs.where((l) => l.transit).length - 1);

class _FakePlanner implements TripPlanner {
  _FakePlanner(this.byProfile);
  final List<List<Itinerary>> byProfile;
  var _call = 0;
  @override
  Future<List<Itinerary>> plan(LatLng from, LatLng to, {PlanOptions options = const PlanOptions()}) async =>
      byProfile[_call++ % byProfile.length];
}

void main() {
  test('merges profiles, dedupes the same trip, groups by line sequence and tags', () async {
    final fast = _it([_walk(0, 4), _ride('211', 'a', 4, 10), _ride('MEB', 'b', 12, 30), _walk(30, 34)]);
    final fastAgainMoreWalk = _it([_walk(0, 8), _ride('211', 'a', 4, 10), _ride('MEB', 'b', 12, 30), _walk(30, 40)]);
    final fastLater = _it([_walk(10, 14), _ride('211', 'c', 14, 20), _ride('MEB', 'd', 22, 40), _walk(40, 44)]);
    final direct = _it([_walk(0, 2), _ride('60', 'e', 2, 45), _walk(45, 46)]);
    final search = RouteSearch(_FakePlanner([
      [fast, fastLater],
      [fastAgainMoreWalk, direct],
      [],
    ]));

    final groups = await search.search(_p, _p);

    expect(groups.map((g) => g.signature), ['211 › MEB', '60']);
    expect(groups.first.options, hasLength(2)); // duplicate trip merged
    expect(groups.first.best.walkMinutes, 8); // kept the version with less walking
    expect(groups.first.tags, {RouteTag.fastest});
    expect(groups[1].tags, {RouteTag.fewestChanges, RouteTag.leastWalking});
  });

  test('one failing profile does not lose the others; all failing rethrows', () async {
    final ok = _it([_walk(0, 2), _ride('60', 'e', 2, 45)]);
    final planner = _ThrowingPlanner([ok]);
    expect(await RouteSearch(planner).search(_p, _p), hasLength(1));
    expect(() => RouteSearch(_ThrowingPlanner(null)).search(_p, _p), throwsException);
  });
}

class _ThrowingPlanner implements TripPlanner {
  _ThrowingPlanner(this.okResult);
  final List<Itinerary>? okResult;
  var _call = 0;
  @override
  Future<List<Itinerary>> plan(LatLng from, LatLng to, {PlanOptions options = const PlanOptions()}) async {
    if (okResult != null && _call++ == 0) return okResult!;
    throw Exception('boom');
  }
}
