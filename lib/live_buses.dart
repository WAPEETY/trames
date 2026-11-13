import 'dart:async';

import 'package:maplibre_gl/maplibre_gl.dart';

import 'backend/backend.dart';

/// A tracked bus: animates from where it is drawn now to the latest GPS fix.
class TrackedBus {
  TrackedBus(this.vehicle, this.color)
      : _from = vehicle.position,
        _to = vehicle.position,
        drawn = vehicle.position;

  Vehicle vehicle;
  final String color;
  LatLng _from;
  LatLng _to;
  LatLng drawn;
  DateTime _animStart = DateTime.now();

  void update(Vehicle v, Duration animDuration) {
    _from = drawn;
    _to = v.position;
    _animStart = DateTime.now();
    vehicle = v;
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

/// Polls vehicle positions for the trip ids of the selected itinerary and pushes
/// interpolated positions to a GeoJSON source on the map.
///
/// Performance notes (the point of this PoC):
///  * buses are a map layer, not Flutter widgets on top of the platform view;
///  * the GeoJSON pushed over the platform channel is tiny (one point per bus);
///  * pushes happen at [frameInterval] only while something is moving.
class LiveBusTracker {
  LiveBusTracker({
    required this.feed,
    required this.onFrame,
    required this.onSnapshot,
    this.pollInterval = const Duration(seconds: 10),
    this.frameInterval = const Duration(milliseconds: 66),
  });

  /// Live GPS source; null where the city has none (then nothing is tracked).
  VehicleFeed? feed;
  final Future<void> Function(Map<String, dynamic> geojson) onFrame;
  final void Function() onSnapshot;
  final Duration pollInterval;
  final Duration frameInterval;

  /// tripId -> leg color
  Map<String, String> _trips = {};
  final Map<String, TrackedBus> buses = {}; // keyed by tripId
  DateTime? lastFeed;
  String? lastError;
  Timer? _poll;
  Timer? _frame;
  bool _pushing = false;

  /// [runs]: run key (see runKeyOf) -> trip id of [tripColors], to follow a
  /// bus the feed lists under another id of the same run.
  void track(Map<String, String> tripColors, {Map<String, String> runs = const {}}) {
    stop();
    _trips = tripColors;
    _runs = runs;
    if (_trips.isEmpty) return;
    _fetch();
    _poll = Timer.periodic(pollInterval, (_) => _fetch());
  }

  /// Follows every live vehicle of [line] (any trip, both directions), in
  /// [color]. Buses that start running later are picked up on the next poll.
  void trackLine(String line, String color) {
    stop();
    _line = line;
    _lineColor = color;
    _fetch();
    _poll = Timer.periodic(pollInterval, (_) => _fetch());
  }

  Map<String, String> _runs = {};
  String? _line;
  String _lineColor = '#000000';

  /// Latest snapshot of all vehicles (e.g. to list a line's directions).
  VehicleSnapshot? lastSnapshot;

  void stop() {
    _poll?.cancel();
    _frame?.cancel();
    _poll = _frame = null;
    buses.clear();
    _trips = {};
    _runs = {};
    _line = null;
    lastFeed = null;
    onFrame(_geojson());
  }

  Future<void> _fetch() async {
    try {
      final f = feed;
      if (f == null) return; // no live GPS in this city
      final snap = await f.vehicles();
      final line = _line;
      if (_trips.isEmpty && line == null) return;
      lastSnapshot = snap;
      lastFeed = snap.feedTimestamp;
      lastError = null;
      final seen = <String>{};
      for (final v in snap.vehicles) {
        var trip = v.tripId;
        if (trip == null) continue;
        // Same run under another trip id: file it under the planned one.
        if (line == null && !_trips.containsKey(trip)) trip = _runs[v.runKey] ?? trip;
        final String color;
        if (line != null) {
          if (v.routeShortName?.toLowerCase() != line.toLowerCase()) continue;
          color = _lineColor;
        } else {
          final c = _trips[trip];
          if (c == null) continue;
          color = c;
        }
        seen.add(trip);
        final existing = buses[trip];
        if (existing == null) {
          buses[trip] = TrackedBus(v, color);
        } else if (existing.vehicle.timestamp != v.timestamp) {
          // Interpolate over one poll interval: continuous movement, ~1 poll of extra lag.
          existing.update(v, pollInterval);
        }
      }
      buses.removeWhere((k, _) => !seen.contains(k));
      _startFrames();
    } catch (e) {
      lastError = '$e';
    }
    onSnapshot();
  }

  void _startFrames() {
    _frame ??= Timer.periodic(frameInterval, (_) async {
      if (_pushing) return; // never queue frames behind a slow platform channel
      var moving = false;
      for (final b in buses.values) {
        moving |= b.tick(pollInterval);
      }
      _pushing = true;
      await onFrame(_geojson());
      _pushing = false;
      if (!moving) {
        _frame?.cancel();
        _frame = null;
      }
    });
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
