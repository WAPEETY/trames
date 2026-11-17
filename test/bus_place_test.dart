import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';

void main() {
  // Three stops ~110 m apart along a meridian; the last is the first again
  // (a loop line).
  final stops = [
    TripStop(name: 'A', position: const LatLng(41.900, 12.5), stopId: 's_a'),
    TripStop(name: 'B', position: const LatLng(41.901, 12.5), stopId: 's_b'),
    TripStop(name: 'C', position: const LatLng(41.902, 12.5), stopId: 's_c'),
    TripStop(name: 'A', position: const LatLng(41.900, 12.5), stopId: 's_a'),
  ];
  Vehicle bus(LatLng at, {String? stopId, int? seq}) => Vehicle(
        id: 'v',
        label: 'v',
        tripId: 't',
        routeShortName: '1',
        position: at,
        timestamp: DateTime(2026),
        stopId: stopId,
        stopSequence: seq,
      );

  test('at the stop it heads to when close, else between', () {
    expect(busPlaceOnTrip(stops, bus(const LatLng(41.90101, 12.5), stopId: 's_b')), (index: 1, atStop: true));
    expect(busPlaceOnTrip(stops, bus(const LatLng(41.9005, 12.5), stopId: 's_b')), (index: 1, atStop: false));
  });

  test('before the first stop it is at it', () {
    expect(busPlaceOnTrip(stops, bus(const LatLng(41.89, 12.5), stopId: 's_a', seq: 1)), (index: 0, atStop: true));
  });

  test('a stop on the trip twice: the one nearest the sequence', () {
    expect(busPlaceOnTrip(stops, bus(const LatLng(41.9015, 12.5), stopId: 's_a', seq: 4)), (index: 3, atStop: false));
  });

  test("another trip's bus: placed by its stop only", () {
    expect(busPlaceOnTrip(stops, bus(const LatLng(41.9015, 12.5), seq: 3), bySequence: false), isNull);
    expect(busPlaceOnTrip(stops, bus(const LatLng(41.90101, 12.5), stopId: 's_b', seq: 9), bySequence: false),
        (index: 1, atStop: true));
  });

  test('sequence alone, and unknown', () {
    expect(busPlaceOnTrip(stops, bus(const LatLng(41.9015, 12.5), seq: 3)), (index: 2, atStop: false));
    expect(busPlaceOnTrip(stops, bus(const LatLng(41.9015, 12.5), stopId: 'elsewhere')), isNull);
    expect(busPlaceOnTrip(stops, bus(const LatLng(41.9015, 12.5))), isNull);
  });
}
