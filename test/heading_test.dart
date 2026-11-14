import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/heading.dart';

void main() {
  test('bearing', () {
    expect(bearingDegrees(const LatLng(41.9, 12.5), const LatLng(41.91, 12.5)), closeTo(0, 0.01));
    expect(bearingDegrees(const LatLng(41.9, 12.5), const LatLng(41.9, 12.51)), closeTo(90, 0.1));
    expect(bearingDegrees(const LatLng(41.9, 12.5), const LatLng(41.89, 12.5)), closeTo(180, 0.01));
    expect(angleBetween(350, 10), 20);
  });

  // North 220 m, then east 160 m.
  const path = [LatLng(41.900, 12.500), LatLng(41.902, 12.500), LatLng(41.902, 12.502)];

  test('on a path: the nearest segment', () {
    expect(headingOnPath(path, const LatLng(41.901, 12.5001)), closeTo(0, 0.5));
    expect(headingOnPath(path, const LatLng(41.9021, 12.501)), closeTo(90, 0.5));
  });

  test('off the path: none', () {
    expect(headingOnPath(path, const LatLng(41.901, 12.505)), isNull);
  });

  test('a street run both ways: the way it was heading', () {
    // Out north, back south on the same street.
    const loop = [LatLng(41.900, 12.500), LatLng(41.902, 12.500), LatLng(41.902, 12.5001), LatLng(41.900, 12.5001)];
    expect(headingOnPath(loop, const LatLng(41.901, 12.50005), hint: 170), closeTo(180, 0.5));
    expect(headingOnPath(loop, const LatLng(41.901, 12.50005), hint: 10), closeTo(0, 0.5));
  });

  test('a move: its direction, none when it barely moved', () {
    expect(headingOfMove(const LatLng(41.9, 12.5), const LatLng(41.9, 12.501)), closeTo(90, 0.1));
    expect(headingOfMove(const LatLng(41.9, 12.5), const LatLng(41.90005, 12.5)), isNull);
  });
}
