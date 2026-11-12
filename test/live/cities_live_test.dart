// Live: stop-number search works without a city config (Milan).
@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/config.dart';

void main() {
  test('stop number in Milan, no config', () async {
    final b = createBackend(city: null);
    const duomo = LatLng(45.4642, 9.1900);
    final stops = await b.stops.nearbyStops(duomo);
    final stop = stops.firstWhere((s) => RegExp(r'^\d{3,7}$').hasMatch(s.code));
    final r = await b.places.search(stop.code, near: duomo);
    // ignore: avoid_print
    print('Milan stop ${stop.code} (${stop.id}) -> ${r.first.name} ${r.first.stopId}');
    expect(r.first.stopId, stop.id);
  }, timeout: const Timeout(Duration(seconds: 90)));
}
