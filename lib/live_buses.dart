import 'dart:async';

import 'package:maplibre_gl/maplibre_gl.dart';

import 'backend/backend.dart';

/// A bus on the map: animates from where it is drawn to its latest position.
class TrackedBus {
  TrackedBus(this.vehicle, this.color)
      : _from = vehicle.position,
        _to = vehicle.position,
        drawn = vehicle.position;

  Vehicle vehicle;
  String color;
  LatLng _from;
  LatLng _to;
  LatLng drawn;
  DateTime _animStart = DateTime.now();

  void update(Vehicle v, String c) {
    _from = drawn;
    _to = v.position;
    _animStart = DateTime.now();
    vehicle = v;
    color = c;
  }

  /// Returns true while still moving.
  bool tick(Duration animDuration) {
    final t = DateTime.now().difference(_animStart).inMilliseconds / animDuration.inMilliseconds;
    final k = t.clamp(0.0, 1.0);
    drawn = LatLng(
      _from.latitude + (_to.latitude - _from.latitude) * k,
      _from.longitude + (_to.longitude - _from.longitude) * k,
    );
    return t < 1.0;
  }
}

/// Draws a set of buses on a GeoJSON map source, animating each from where
/// it is to its newest position. Whoever follows the buses (a ride, a line,
/// the map area) pushes them with [show]; this only draws.
///
/// Buses are a map layer, not widgets over the platform view; frames are
/// pushed at [frameInterval] only while something moves.
class LiveBusTracker {
  LiveBusTracker({
    required this.onFrame,
    this.animation = const Duration(seconds: 4),
    this.frameInterval = const Duration(milliseconds: 66),
  });

  final Future<void> Function(Map<String, dynamic> geojson) onFrame;

  /// How long a bus takes to glide to a new position.
  final Duration animation;
  final Duration frameInterval;

  /// Shown buses by key (a ride's trip id, or a vehicle id).
  final Map<String, TrackedBus> buses = {};

  /// Newest position time among the shown buses.
  DateTime? lastFeed;
  Timer? _frame;
  bool _pushing = false;

  /// Shows exactly [next] (key -> bus and colour): new ones appear, known
  /// ones glide to their new position, missing ones go.
  void show(Map<String, ({Vehicle vehicle, String color})> next) {
    for (final MapEntry(:key, value: (:vehicle, :color)) in next.entries) {
      final existing = buses[key];
      if (existing == null) {
        buses[key] = TrackedBus(vehicle, color);
      } else if (existing.vehicle.timestamp != vehicle.timestamp || existing.color != color) {
        existing.update(vehicle, color);
      }
    }
    buses.removeWhere((k, _) => !next.containsKey(k));
    lastFeed = buses.values.map((b) => b.vehicle.timestamp).fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    _frame ??= Timer.periodic(frameInterval, (_) => _tick());
  }

  void clear() {
    _frame?.cancel();
    _frame = null;
    buses.clear();
    lastFeed = null;
    onFrame(_geojson());
  }

  Future<void> _tick() async {
    if (_pushing) return; // never queue frames behind a slow platform channel
    var moving = false;
    for (final b in buses.values) {
      moving |= b.tick(animation);
    }
    _pushing = true;
    await onFrame(_geojson());
    _pushing = false;
    if (!moving) {
      _frame?.cancel();
      _frame = null;
    }
  }

  Map<String, dynamic> _geojson() => {
        'type': 'FeatureCollection',
        'features': [
          for (final b in buses.values)
            {
              'type': 'Feature',
              'geometry': {
                'type': 'Point',
                'coordinates': [b.drawn.longitude, b.drawn.latitude],
              },
              'properties': {
                'line': b.vehicle.routeShortName ?? '',
                'color': b.color,
              },
            },
        ],
      };
}
