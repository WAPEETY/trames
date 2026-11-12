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
    final trimmed = RouteSearch(_NoPlanner(), clock: () => _t0).trimAlternatives(it);
    final alts = trimmed.transitLegs.single.alternatives;
    expect(alts.map((a) => a.line), ['MEB1']); // the 88 boards ~900 m away: not an alternative
  });

  test('routes differing only by an interchangeable line are one route', () {
    final search = RouteSearch(_NoPlanner(), clock: () => _t0);
    Itinerary trip(int dep, String second, List<String> alts) => Itinerary(start: _m(dep), end: _m(dep + 30), transfers: 1, legs: [
          _ride('60', _concaBus, _policlinico, dep, dep + 18),
          _walk(_policlinico, _policlinico, dep + 18, dep + 20),
          _ride(second, _policlinico, _verano, dep + 22, dep + 30, alts: [
            for (final l in alts)
              LegAlternative([_walk(_policlinico, _policlinico, 0, 0), _ride(l, _policlinico, _verano, dep + 24, dep + 31), _walk(_verano, _verano, 0, 0)]),
          ]),
        ]);
    final groups = search.group([trip(0, '19BUS', ['3BUS', '88']), trip(40, '3BUS', ['88']), trip(20, '62', [])]);
    expect(groups.map((g) => g.signature), ['60 › 19BUS', '60 › 62']); // the 62 has no line in common
    expect(groups.first.options.map((it) => it.start), [_m(0), _m(40)]);
  });
}

class _NoPlanner implements TripPlanner {
  @override
  Future<List<Itinerary>> plan(LatLng from, LatLng to, {PlanOptions options = const PlanOptions()}) async => const [];
}
