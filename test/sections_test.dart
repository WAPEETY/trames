import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/route_search.dart';

// A row of the journey list only holds journeys of one section (live,
// predicted, scheduled): MR728A (timetable) and the 135 (live, yellow)
// doing the same stretch were merged into one "MR728A / 135" row under
// Scheduled, hiding the live 135 behind a swipe.

final _t0 = DateTime.now().add(const Duration(minutes: 5));
DateTime _m(int min) => _t0.add(Duration(minutes: min));
const _a = LatLng(41.936, 12.514), _b = LatLng(41.910, 12.530);

Leg _walk(int s, int e) => Leg(
    mode: 'WALK', transit: false, start: _m(s), end: _m(e), fromName: '', toName: '', from: _a, to: _a,
    points: const [], distanceMeters: 100);
Leg _ride(String line, String trip, int s, int e, {bool live = false, List<LegAlternative> alts = const []}) => Leg(
    mode: 'BUS', transit: true, start: _m(s), end: _m(e), fromName: '', toName: '', from: _a, to: _b,
    points: const [], distanceMeters: 0, routeShortName: line, tripId: trip, backendTripId: trip, realtime: live,
    alternatives: alts);
Itinerary _it(List<Leg> legs) =>
    Itinerary(start: legs.first.start, end: legs.last.end, legs: legs, transfers: legs.where((l) => l.transit).length - 1);

class _NoPlanner implements TripPlanner {
  @override
  Future<List<Itinerary>> plan(LatLng from, LatLng to, {PlanOptions options = const PlanOptions()}) async => const [];
}

void main() {
  final alt135 = LegAlternative([_ride('135', 'b135', 23, 32, live: true)]);
  final mr728a = _it([_walk(0, 4), _ride('MR728A', 'mr', 4, 13, alts: [alt135]), _walk(13, 19)]);
  final live135 = _it([_walk(18, 23), _ride('135', 'b135', 23, 32, live: true), _walk(32, 38)]);
  String section(Itinerary it) => it.transitLegs.every((l) => l.realtime) ? 'live' : 'scheduled';

  test('without sections they share a row (the old behaviour)', () {
    expect(RouteSearch(_NoPlanner()).group([mr728a, live135]), hasLength(1));
  });

  test('with sections each journey gets a row in its own section', () {
    final groups = RouteSearch(_NoPlanner()).group([mr728a, live135], sectionOf: section);
    expect(groups, hasLength(2));
    for (final g in groups) {
      expect(g.options.map(section).toSet(), hasLength(1)); // a row never mixes sections
    }
    expect(groups.firstWhere((g) => section(g.best) == 'live').best.transitLegs.single.routeShortName, '135');
  });
}
