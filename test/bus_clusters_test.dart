import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/bus_clusters.dart';

void main() {
  const view = (width: 400.0, height: 400.0);

  test('zooms in until the nearest two are more than the radius apart', () {
    // Two buses 40 m apart at zoom 13: ~2 px apart there.
    const a = LatLng(41.9, 12.5), b = LatLng(41.90036, 12.5);
    final t = clusterZoomTarget([a, b], zoom: 13, viewPx: view);
    expect(40 / metersPerPixel(t.zoom, 41.9), greaterThan(kBusClusterRadiusPx));
    expect(t.center.latitude, closeTo(41.90018, 1e-6));
  });

  test('keeps them all in view, and goes in at least one level', () {
    // Far apart (2 km) but two of them 5 m apart: fitting wins.
    final t = clusterZoomTarget(
        [const LatLng(41.9, 12.5), const LatLng(41.918, 12.5), const LatLng(41.90004, 12.5)],
        zoom: 12, viewPx: view);
    expect(2000 / metersPerPixel(t.zoom, 41.9), lessThanOrEqualTo(400));
    expect(t.zoom, greaterThanOrEqualTo(13));
  });

  test('buses at the same spot: up to the max zoom only', () {
    final t = clusterZoomTarget([const LatLng(41.9, 12.5), const LatLng(41.9, 12.5)], zoom: 14, viewPx: view);
    expect(t.zoom, 18);
  });
}
