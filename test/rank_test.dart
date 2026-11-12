import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';

Place _p(String n, double lat, double lon) => Place(name: n, position: LatLng(lat, lon));

void main() {
  const rome = LatLng(41.90, 12.50);
  test('local results first in relevance order, then the rest by distance', () {
    final ranked = rankByProximity([
      _p('Ojetti (Florence)', 43.79, 11.25), // ~240 km
      _p('Ojetti/Aleramo (Rome)', 41.93, 12.54),
      _p('Ojetti (Milan)', 45.46, 9.19), // ~480 km
      _p('Ojetti/Primoli (Rome)', 41.92, 12.54),
      _p('Ojetti (Tivoli)', 41.96, 12.80), // ~26 km
    ], rome);
    expect(ranked.map((p) => p.name), [
      'Ojetti/Aleramo (Rome)', // local, keeps backend order
      'Ojetti/Primoli (Rome)',
      'Ojetti (Tivoli)', // then nearest first
      'Ojetti (Florence)',
      'Ojetti (Milan)',
    ]);
  });
}
