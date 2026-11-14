// Live smoke test against the real services: flutter test test/live
@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/config.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/route_search.dart';

void main() {
  final b = transitousRome();
  const here = LatLng(41.9248, 12.5450);
  const termini = LatLng(41.9010, 12.5013);

  test('plan', () async {
    final its = await b.planner.plan(here, termini);
    expect(its, isNotEmpty);
    for (final it in its.take(3)) {
      // ignore: avoid_print
      print('${it.start} -> ${it.end} ${it.transitLegs.map((l) => '${l.routeShortName}[${l.tripId}] rt=${l.realtime} d=${l.delaySeconds} pts=${l.points.length}').join(' + ')}');
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('search', () async {
    final r = await b.places.search('colosseo', near: here);
    // ignore: avoid_print
    print(r.take(3).map((p) => '${p.name} | ${p.subtitle}').join('\n'));
    expect(r, isNotEmpty);
  });

  test('nearby + board', () async {
    final stops = await b.stops.nearbyStops(here);
    expect(stops, isNotEmpty);
    final rows = await b.stops.board(stops.first);
    // ignore: avoid_print
    print('${stops.first.name} ${stops.first.distanceMeters}m: ${rows.map((r) => '${r.line}->${r.headsign} ${r.next.length}x rt=${r.next.first.realtime}').join(', ')}');
  });

  test('grouped route search + leg alternatives', () async {
    final groups = await RouteSearch(b.planner).search(here, const LatLng(41.8902, 12.4922));
    expect(groups, isNotEmpty);
    for (final g in groups) {
      final alts = g.best.transitLegs.map((l) => '${l.routeShortName}: or ${l.alternatives.map((a) => a.line).toSet().join('/')}').join('; ');
      // ignore: avoid_print
      print('${g.signature.padRight(28)} ${g.options.length}x tags=${g.tags.map((t) => t.name)} | $alts');
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('trip path of a ride', () async {
    final groups = await RouteSearch(b.planner).search(here, const LatLng(41.8902, 12.4922));
    final leg = groups.first.best.transitLegs.first;
    final path = await b.paths!.tripPath(leg);
    // ignore: avoid_print
    print('${leg.routeShortName} [${leg.tripId}] path ${path.length} pts');
    expect(path.length, greaterThan(1));
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('line view: trip of a ride, stops, search kinds', () async {
    final groups = await RouteSearch(b.planner).search(here, const LatLng(41.8902, 12.4922));
    final leg = groups.first.best.transitLegs.first;
    final t = await b.trips!.trip(leg.backendTripId!);
    // ignore: avoid_print
    print('line ${leg.routeShortName} -> ${t.line} "${t.headsign}" ${t.stops.length} stops, ${t.points.length} pts, rt=${t.realtime}');
    expect(t.stops.length, greaterThan(1));
    final places = await b.places.search('termini', near: here);
    // ignore: avoid_print
    print(places.take(3).map((p) => '${p.name} ${p.kind} ${p.stopId}').join(' | '));
    expect(places.any((p) => p.kind == PlaceKind.stop && p.stopId != null), isTrue);
    final rows = await b.stops.board(Stop(id: places.firstWhere((p) => p.stopId != null).stopId!, name: 'x', position: here, distanceMeters: 0));
    expect(rows.every((r) => r.next.first.backendTripId != null), isTrue);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('walk rules live: San Lorenzo -> Termini, and a 3 km walk', () async {
    final cache = WalkCache(b.walks!);
    const sanLorenzo = LatLng(41.8987, 12.5177);
    final groups = await RouteSearch(b.planner, walks: cache).search(sanLorenzo, termini);
    for (final g in groups) {
      final it = g.best;
      // ignore: avoid_print
      print('${g.isWalk ? 'WALK' : g.signature.padRight(18)} ${it.duration.inMinutes} min, arrive ${it.end.toLocal().toIso8601String().substring(11, 16)}'
          ' tags=${g.tags.map((t) => t.name)} walked=${it.walkSlots} legs=${it.legs.map((l) => l.transit ? l.routeShortName : 'walk${l.duration.inMinutes}').join(',')}');
    }
    final w = await b.walks!.walk(sanLorenzo, const LatLng(41.8902, 12.4922)); // ~2.3 km to the Colosseum
    // ignore: avoid_print
    print('walk to Colosseum: ${w?.duration.inMinutes} min, ${w?.distanceMeters.round()} m, ${w?.points.length} pts');
    expect(w, isNotNull);
  }, timeout: const Timeout(Duration(seconds: 120)));
}
