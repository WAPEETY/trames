import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/route_search.dart';

final _t0 = DateTime(2026, 11, 12, 14);
DateTime _m(int min) => _t0.add(Duration(minutes: min));

const _policlinico = LatLng(41.9077, 12.5115);
const _verano = LatLng(41.90215, 12.51899); // ~900 m from Policlinico
const _concaMetro = LatLng(41.93898, 12.52736);
const _concaBus = LatLng(41.94003, 12.52944); // ~200 m from the metro stop

Leg _ride(String line, LatLng f, LatLng t, int a, int b, {List<LegAlternative> alts = const []}) => Leg(
    mode: line.startsWith('ME') ? 'SUBWAY' : 'BUS', transit: true, start: _m(a), end: _m(b), fromName: line, toName: line,
    from: f, to: t, points: const [], distanceMeters: 0, routeShortName: line, tripId: '$line$a', alternatives: alts);
Leg _walk(LatLng f, LatLng t, int a, int b) => Leg(
    mode: 'WALK', transit: false, start: _m(a), end: _m(b), fromName: '', toName: '', from: f, to: t, points: const [], distanceMeters: 0);

void main() {
  test('only alternatives boarding and alighting within 300 m are kept', () {
    final laterMetro = LegAlternative([_walk(_verano, _policlinico, 10, 19), _ride('MEB1', _policlinico, _concaMetro, 19, 32), _walk(_concaMetro, _concaBus, 32, 35)]);
    final bus88 = LegAlternative([_walk(_verano, _verano, 0, 1), _ride('88', _verano, _concaBus, 1, 28), _walk(_concaBus, _concaBus, 28, 29)]);
    final metro = _ride('MEB1', _policlinico, _concaMetro, 10, 23, alts: [laterMetro, bus88]);
    final it = Itinerary(start: _m(0), end: _m(26), transfers: 0, legs: [
      _walk(_verano, _policlinico, 0, 10), metro, _walk(_concaMetro, _concaBus, 23, 26),
    ]);
    final trimmed = RouteSearch(_NoPlanner()).trimAlternatives(it);
    final alts = trimmed.transitLegs.single.alternatives;
    expect(alts.map((a) => a.line), ['MEB1']); // the 88 boards ~900 m away: not an alternative
  });
}

class _NoPlanner implements TripPlanner {
  @override
  Future<List<Itinerary>> plan(LatLng from, LatLng to, {PlanOptions options = const PlanOptions()}) async => const [];
}
