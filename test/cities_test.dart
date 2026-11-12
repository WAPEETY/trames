import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/config.dart';
import 'package:roma_transit/backend/motis.dart';

void main() {
  test('city from a position', () {
    expect(cityAt(const LatLng(41.9010, 12.5013))?.id, 'rome'); // Termini
    expect(cityAt(const LatLng(41.79, 12.25))?.id, 'rome'); // Fiumicino side
    expect(cityAt(const LatLng(45.4642, 9.1900)), isNull); // Milan: Transitous only
  });

  test('backend: Rome has live GPS, elsewhere Transitous only', () {
    final rome = createBackend(city: kRomeConfig);
    expect(rome.vehicles, isNotNull);
    expect(rome.city?.id, 'rome');
    final elsewhere = createBackend(city: null);
    expect(elsewhere.vehicles, isNull);
    expect(elsewhere.city, isNull);
    // Transitous features stay available everywhere.
    expect(elsewhere.trips, isNotNull);
    expect(elsewhere.walks, isNotNull);
    expect(elsewhere.paths, isNotNull);
  });

  test('a live vehicle maps to a trip only with a feed id', () {
    final v = Vehicle(
      id: '1', label: '1', tripId: '0#1-1', routeShortName: '88', position: const LatLng(0, 0),
      timestamp: DateTime(2026), startDate: '20261112', startTime: '14:45:00');
    expect(MotisClient(vehicleFeedId: 'it-Lazio-Rome').tripIdForVehicle(v), '20261112_14:45_it-Lazio-Rome_0#1-1');
    expect(MotisClient().tripIdForVehicle(v), isNull);
  });
}
