import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/config.dart';

void main() {
  test('city from a position', () {
    expect(cityAt(const LatLng(41.9010, 12.5013))?.id, 'rome'); // Termini
    expect(cityAt(const LatLng(41.79, 12.25))?.id, 'rome'); // Fiumicino side
    expect(cityAt(const LatLng(45.4642, 9.1900)), isNull); // Milan: Transitous only
  });

  test('backend: Transitous everywhere, a home feed only in a configured city', () {
    final rome = createBackend(city: kRomeConfig);
    expect(rome.city?.id, 'rome');
    final elsewhere = createBackend(city: null);
    expect(elsewhere.city, isNull);
    expect(elsewhere.trips, isNotNull);
    expect(elsewhere.walks, isNotNull);
    expect(elsewhere.paths, isNotNull);
  });
}
