import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/preferences.dart';
import 'package:roma_transit/backend/route_search.dart';

// The whole search pipeline (rule 1, walking rule, rule 2, duplicates,
// grouping) on the PL2D case from the app: walk > RI403A > walk > PL2D >
// X (a 1.5-min bus) > walk. The walking rule prefers walking over the X,
// so the journey shown already stays on the PL2D: it must stay listed.

final _t0 = DateTime.now().add(const Duration(minutes: 5));
DateTime _m(num min) => _t0.add(Duration(seconds: (min * 60).round()));
LatLng _p(int i) => LatLng(41.93, 12.53 - 0.004 * i); // PL2D stops, ~330 m apart
final _dest = LatLng(41.9318, _p(2).longitude); // ~200 m from P2
final _q = LatLng(41.9316, _p(2).longitude); // where the X stops, near the destination
const _origin = LatLng(41.935, 12.51);

Leg _walk(num a, num b, LatLng f, LatLng t) => Leg(
    mode: 'WALK', transit: false, start: _m(a), end: _m(b), fromName: '', toName: '', from: f, to: t,
    points: [f, t], distanceMeters: distanceMeters(f, t));
Leg _ride(String line, num a, num b, LatLng f, LatLng t, String fs, String ts) => Leg(
    mode: 'BUS', transit: true, start: _m(a), end: _m(b), fromName: fs, toName: ts, from: f, to: t, points: [f, t],
    distanceMeters: 0, routeShortName: line, tripId: line, backendTripId: line, fromStopId: fs, toStopId: ts, realtime: true);

class _Planner implements TripPlanner {
  _Planner(this.journeys);
  final List<Itinerary> Function() journeys;
  @override
  Future<List<Itinerary>> plan(LatLng from, LatLng to, {PlanOptions options = const PlanOptions()}) async => journeys();
}

Itinerary _pl2dJourney() {
  final legs = [
    _walk(0, 4, _origin, _p(-2)),
    _ride('RI403A', 4, 6, _p(-2), _p(-1), 'a0', 'a1'),
    _walk(6, 10, _p(-1), _p(0)),
    _ride('PL2D', 10, 16, _p(0), _p(2), 'p0', 'p2'),
    _ride('X', 16.5, 18, _p(2), _q, 'p2', 'q'),
    _walk(18, 18.5, _q, _dest),
  ];
  return Itinerary(start: legs.first.start, end: legs.last.end, legs: legs, transfers: 2);
}

class _Runs implements TripDetails {
  @override
  Future<TripInfo> trip(String id) async => switch (id) {
        'PL2D' => TripInfo(line: 'PL2D', mode: 'BUS', headsign: '', points: [for (var i = 0; i < 5; i++) _p(i)], realtime: true,
            stops: [for (var i = 0; i < 5; i++) TripStop(name: 'P$i', position: _p(i), stopId: 'p$i', time: _m(10 + 3 * i), live: true)]),
        'X' => TripInfo(line: 'X', mode: 'BUS', headsign: '', points: [_p(2), _q, _dest], realtime: true, stops: [
            TripStop(name: 'P2', position: _p(2), stopId: 'p2', time: _m(16.5), live: true),
            TripStop(name: 'Q', position: _q, stopId: 'q', time: _m(18), live: true),
            TripStop(name: 'D', position: _dest, stopId: 'd', time: _m(19), live: true),
          ]),
        _ => throw Exception('unknown run'),
      };
  @override
  Future<String?> sameRun(String tripId, {required String stopId, required DateTime at, String? line}) async => null;
}

class _Walks implements WalkRouter {
  @override
  Future<WalkRoute?> walk(LatLng from, LatLng to) async {
    final m = distanceMeters(from, to);
    return WalkRoute(duration: Duration(seconds: (m / 1.2).round()), distanceMeters: m, points: [from, to]);
  }
}

RouteSearch _search(List<Itinerary> Function() journeys) => RouteSearch(_Planner(journeys),
    walks: WalkCache(_Walks()),
    trips: _Runs(),
    policy: WalkLiking.aBit.policy,
    rank: RoutePreference.balanced.rank,
    stayOn: RoutePreference.balanced.stayOn,
    profiles: const [PlanProfile('default', PlanOptions())]);

String _describe(Itinerary it) =>
    it.legs.map((l) => l.transit ? '${l.routeShortName}>${l.toStopId}' : 'walk').join(' ');

void main() {
  test('PL2D case: the X becomes a walk, so the journey stays on the PL2D and stays listed', () async {
    final groups = await _search(() => [_pl2dJourney()]).search(_origin, _dest);
    final shown = groups.where((g) => g.hiddenBecause == null).toList();
    expect(groups.where((g) => g.hiddenBecause != null), isEmpty);
    expect(shown.map((g) => _describe(g.best)), contains('walk RI403A>a1 walk PL2D>p2 walk'));
  });

  test('the X was the last bus: "stay on the X" is not added again (it is the swipe option)', () async {
    final groups = await _search(() => [_pl2dJourney()]).search(_origin, _dest);
    final all = [for (final g in groups) ...g.options];
    expect(all.map(_describe), isNot(contains(startsWith('walk RI403A>a1 walk PL2D>p2 X>'))));
  });

  test('a walked bus with a change after it yields "take it and stay on" (added, hides nothing)', () async {
    // PL2D > X (50 s, walked: not slower on foot) > Y. Staying on the X
    // instead of changing to the Y must be offered.
    final near = LatLng(_p(2).latitude, _p(2).longitude - 0.0007); // ~60 m from P2
    Itinerary journey() {
      final legs = [
        _walk(0, 4, _origin, _p(-2)),
        _ride('RI403A', 4, 6, _p(-2), _p(-1), 'a0', 'a1'),
        _walk(6, 10, _p(-1), _p(0)),
        _ride('PL2D', 10, 16, _p(0), _p(2), 'p0', 'p2'),
        _ride('X', 16.5, 18, _p(2), near, 'p2', 'q'),
        _ride('Y', 19, 22, near, _dest, 'q', 'd'),
      ];
      return Itinerary(start: legs.first.start, end: legs.last.end, legs: legs, transfers: 3);
    }

    final groups = await _search(() => [journey()]).search(_origin, _dest);
    final all = [for (final g in groups) ...g.options];
    // The X really went through the walking rule (slot 2 = third bus).
    expect(all.any((it) => it.walkSlots.contains(2)), isTrue);
    expect(all.map(_describe), contains(startsWith('walk RI403A>a1 walk PL2D>p2 X>')));
    expect(all.where((it) => _describe(it).contains('X>')).every((it) => it.hiddenBecause == null), isTrue);
  });

  test('the same journey shown and hidden: the shown one is kept', () {
    final it = _pl2dJourney();
    final hidden = it.hiddenFor(StayOnReason(line: 'PL2D', arrival: _m(20), changesSaved: 1));
    final groups = RouteSearch(_Planner(() => const [])).group([hidden, it]);
    expect(groups.single.hiddenBecause, isNull);
  });
}
