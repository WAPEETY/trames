import 'package:maplibre_gl/maplibre_gl.dart';

import 'backend.dart';

/// Guesses that you're riding a bus: one live bus stays near you while you
/// move with it. Standing at a stop while a bus waits there doesn't count
/// (you don't move); a bus passing by doesn't either (it doesn't stay near).
///
/// Bus positions lag behind the real bus (GPS every ~30 s), hence the
/// generous [nearMeters].
class BoardDetector {
  BoardDetector({
    this.nearMeters = 100,
    this.minTime = const Duration(seconds: 20),
    this.minMoveMeters = 100,
    this.snooze = const Duration(minutes: 1),
  });

  final double nearMeters;

  /// How long the same bus must stay near...
  final Duration minTime;

  /// ...while you move at least this far.
  final double minMoveMeters;

  /// A bus you said "no" to isn't asked about again for this long.
  final Duration snooze;

  String? _candidate;
  DateTime? _since;
  LatLng? _start;
  final _dismissed = <String, DateTime>{};

  /// The bus (its key in [buses]) you seem to be riding, given where you are
  /// at [now]; null while unsure. Call on every position update.
  String? update(LatLng here, Map<String, LatLng> buses, DateTime now) {
    String? nearest;
    var best = nearMeters;
    for (final MapEntry(key: id, value: p) in buses.entries) {
      if (_snoozed(id, now)) continue;
      final d = distanceMeters(here, p);
      if (d <= best) {
        best = d;
        nearest = id;
      }
    }
    if (nearest == null) {
      _candidate = null;
      return null;
    }
    if (nearest != _candidate) {
      _candidate = nearest;
      _since = now;
      _start = here;
      return null;
    }
    final riding = now.difference(_since!) >= minTime && distanceMeters(_start!, here) >= minMoveMeters;
    return riding ? nearest : null;
  }

  /// "No, I'm not on [id]": not asked again for [snooze]; other buses may be.
  void dismiss(String id, DateTime now) {
    _dismissed[id] = now;
    _dismissed.removeWhere((_, t) => now.difference(t) >= snooze);
    if (_candidate == id) _candidate = null;
  }

  bool _snoozed(String id, DateTime now) {
    final t = _dismissed[id];
    return t != null && now.difference(t) < snooze;
  }
}
