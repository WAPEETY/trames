import 'dart:math' as math;

import 'package:maplibre_gl/maplibre_gl.dart';

import 'backend.dart' show distanceMeters;

/// Compass bearing from [a] to [b], degrees clockwise from north (0–360).
double bearingDegrees(LatLng a, LatLng b) {
  final p1 = a.latitude * math.pi / 180, p2 = b.latitude * math.pi / 180;
  final dl = (b.longitude - a.longitude) * math.pi / 180;
  final y = math.sin(dl) * math.cos(p2);
  final x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

/// Smallest angle between two bearings (0–180).
double angleBetween(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

/// Which way a vehicle at [p] heads along [path] (its trip's shape, in
/// driving order): the bearing of the path segment nearest to it. Null when
/// it's more than [maxMeters] off the path.
///
/// Where the path passes the same street twice (out and back on a loop),
/// segments about as near as the nearest (within [tieMeters]) are told
/// apart by [hint], the way it was last seen heading.
double? headingOnPath(List<LatLng> path, LatLng p, {double? hint, double maxMeters = 60, double tieMeters = 15}) {
  if (path.length < 2) return null;
  // Local flat projection around p, in metres.
  final kLat = 111320.0, kLon = 111320.0 * math.cos(p.latitude * math.pi / 180);
  (double, double) xy(LatLng q) => ((q.longitude - p.longitude) * kLon, (q.latitude - p.latitude) * kLat);

  final candidates = <(double dist, double bearing)>[];
  for (var i = 0; i + 1 < path.length; i++) {
    final a = path[i], b = path[i + 1];
    final (ax, ay) = xy(a);
    final (bx, by) = xy(b);
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    if (len2 < 0.25) continue; // repeated point
    final t = (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0);
    final cx = ax + t * dx, cy = ay + t * dy;
    candidates.add((math.sqrt(cx * cx + cy * cy), bearingDegrees(a, b)));
  }
  if (candidates.isEmpty) return null;
  final nearest = candidates.map((c) => c.$1).reduce(math.min);
  if (nearest > maxMeters) return null;
  final close = candidates.where((c) => c.$1 <= nearest + tieMeters);
  if (hint == null) return candidates.firstWhere((c) => c.$1 == nearest).$2;
  return close.reduce((a, b) => angleBetween(a.$2, hint) <= angleBetween(b.$2, hint) ? a : b).$2;
}

/// Heading from a move from [from] to [to]; null when it moved less than
/// [minMeters] (GPS jitter, or standing still), so the last one is kept.
double? headingOfMove(LatLng from, LatLng to, {double minMeters = 15}) =>
    distanceMeters(from, to) < minMeters ? null : bearingDegrees(from, to);
