import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/models.dart';

void main() {
  // A straight eastbound path, points every 0.001° of longitude.
  final path = [for (var i = 0; i <= 10; i++) LatLng(41.9, 12.50 + i * 0.001)];

  test('vehicle before the stop: path from vehicle to stop', () {
    final seg = approachPath(path, const LatLng(41.9001, 12.5021), const LatLng(41.9, 12.507));
    expect(seg.first, const LatLng(41.9001, 12.5021)); // starts at the bus
    expect(seg.last.longitude, closeTo(12.507, 1e-9)); // ends at the stop
    expect(seg.length, 1 + 5); // bus + path points 3..7
  });

  test('vehicle past the stop: nothing to draw', () {
    expect(approachPath(path, const LatLng(41.9, 12.509), const LatLng(41.9, 12.503)), isEmpty);
  });

  test('loop route: vehicle matched only before the stop', () {
    // out and back: the return leg passes the start again after the stop
    final loop = [...path, ...path.reversed.skip(1)];
    final seg = approachPath(loop, const LatLng(41.9, 12.501), const LatLng(41.9, 12.510));
    expect(seg, isNotEmpty);
    expect(seg.last.longitude, closeTo(12.510, 1e-9));
  });
}
