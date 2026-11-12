// Live: search by stop number, and twin stops have distinct ids.
@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/config.dart';

void main() {
  final b = transitousRome();
  test('stop number finds that exact stop first', () async {
    final r = await b.places.search('71502', near: const LatLng(41.91, 12.52));
    expect(r.first.stopId, 'it-Lazio-Rome_71502');
    expect(r.first.name, 'NOMENTANA/REGINA MARGHERITA');
    expect(r.first.station, isFalse);
  });
  test('metro station is a station, bus stop is not', () async {
    final r = await b.places.search('termini', near: const LatLng(41.90, 12.50));
    expect(r.firstWhere((p) => p.stopId == 'it-Lazio-Rome_AD12').station, isTrue);
    final bus = await b.places.search('ojetti primoli', near: const LatLng(41.94, 12.55));
    expect(bus.firstWhere((p) => p.kind == PlaceKind.stop).station, isFalse);
  });
  test('the twin across the road is found by area lookup', () async {
    const p = LatLng(41.91259, 12.50638); // NOMENTANA/REGINA MARGHERITA 71502
    final near = await b.stops.stopsInArea(
        LatLngBounds(southwest: LatLng(p.latitude - 0.0014, p.longitude - 0.0019), northeast: LatLng(p.latitude + 0.0014, p.longitude + 0.0019)),
        from: p);
    final twins = near.where((s) => s.name == 'NOMENTANA/REGINA MARGHERITA').map((s) => s.code).toSet();
    expect(twins, containsAll(['71502', '71572']));
  });
}
