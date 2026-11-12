// Live: a tapped pin shows only its own stop (one direction).
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/config.dart';

void main() {
  test('Nomentana/Regina Margherita pins: one direction each', () async {
    final b = transitousRome();
    final places = await b.places.search('Nomentana Regina Margherita', near: const LatLng(41.915, 12.515));
    final p = places.firstWhere((p) => p.kind == PlaceKind.stop);
    final stops = (await b.stops.nearbyStops(p.position))
        .where((s) => s.name.toUpperCase().contains('NOMENTANA') && s.name.toUpperCase().contains('MARGHERITA'))
        .toList();
    expect(stops.length, greaterThanOrEqualTo(2)); // the two sides of the road
    final heads = <String, Set<String>>{};
    for (final s in stops) {
      final rows = await b.stops.board(s);
      heads[s.id] = {for (final r in rows) '${r.line}->${r.headsign}'};
      // ignore: avoid_print
      print('${s.id} ${s.name}: ${heads[s.id]}');
    }
    // Same line never in both directions on one pin.
    for (final h in heads.values) {
      final byLine = <String, Set<String>>{};
      for (final x in h) {
        final parts = x.split('->');
        (byLine[parts[0]] ??= {}).add(parts[1]);
      }
      expect(byLine.values.where((dirs) => dirs.length > 1), isEmpty, reason: 'a line shows two directions: $byLine');
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
