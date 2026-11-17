import 'dart:math' as math;

import 'package:maplibre_gl/maplibre_gl.dart';

import 'backend/backend.dart';

/// Browsing buses that overlap by more than a quarter of their width merge
/// into one bubble with their count: centers closer than 3/4 of a bus
/// circle's diameter (radius 11 px). MapLibre clusters at whole zoom levels,
/// so between two levels the cut is only roughly this.
const kBusClusterRadiusPx = 16.0;

/// Meters per screen pixel at [zoom] and [latitude] (512 px tiles).
double metersPerPixel(double zoom, double latitude) =>
    78271.517 * math.cos(latitude * math.pi / 180) / math.pow(2, zoom);

/// Where to zoom so the bubble's buses [members] stand apart: centered on
/// them, far enough in that no two are within [radiusPx] (MapLibre splits a
/// cluster at whole zoom levels, hence the ceiling), but no further than
/// still shows them all in a [viewPx] (width, height) view, and at most
/// [maxZoom] (buses at the same spot never split). Always at least one level
/// in from [zoom].
({LatLng center, double zoom}) clusterZoomTarget(
  List<LatLng> members, {
  required double zoom,
  required ({double width, double height}) viewPx,
  double radiusPx = kBusClusterRadiusPx,
  double maxZoom = 18,
}) {
  var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
  for (final p in members) {
    minLat = math.min(minLat, p.latitude);
    maxLat = math.max(maxLat, p.latitude);
    minLon = math.min(minLon, p.longitude);
    maxLon = math.max(maxLon, p.longitude);
  }
  final center = LatLng((minLat + maxLat) / 2, (minLon + maxLon) / 2);
  double zoomFor(double meters, double pixels) =>
      math.log(78271.517 * math.cos(center.latitude * math.pi / 180) * pixels / meters) / math.ln2;

  // Nearest two: they must end up more than the cluster radius apart.
  var nearest = double.infinity;
  for (var i = 0; i < members.length; i++) {
    for (var j = i + 1; j < members.length; j++) {
      nearest = math.min(nearest, distanceMeters(members[i], members[j]));
    }
  }
  final apart = nearest <= 0.5 ? maxZoom : (zoomFor(nearest, radiusPx * 1.1)).ceilToDouble();
  // All of them in view, with a margin.
  final spanX = distanceMeters(LatLng(center.latitude, minLon), LatLng(center.latitude, maxLon));
  final spanY = distanceMeters(LatLng(minLat, center.longitude), LatLng(maxLat, center.longitude));
  final fitX = spanX <= 0.5 ? maxZoom : zoomFor(spanX, viewPx.width * 0.7);
  final fitY = spanY <= 0.5 ? maxZoom : zoomFor(spanY, viewPx.height * 0.7);
  final target = math.min(math.min(apart, math.min(fitX, fitY)), maxZoom);
  return (center: center, zoom: math.max(target, math.min(zoom + 1, maxZoom)));
}
