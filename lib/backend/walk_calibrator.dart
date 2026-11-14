import 'dart:math' as math;

import 'package:maplibre_gl/maplibre_gl.dart';

import 'backend.dart' show distanceMeters;

/// One GPS fix, as the calibrator needs it.
class WalkFix {
  const WalkFix({required this.position, required this.time, required this.accuracy, this.speed});
  final LatLng position;
  final DateTime time;

  /// Horizontal accuracy, meters.
  final double accuracy;

  /// Speed reported by the GPS, m/s (null or negative: unknown).
  final double? speed;
}

/// Learns your walking pace from GPS while the app is open.
///
/// Good fixes (accuracy ≤ [maxAccuracy]) are grouped into walking segments;
/// a stop longer than [maxPause] ends one (traffic lights don't, so the pace
/// includes them, like the planner's walking times should). A segment
/// counts when it lasts ≥ [minSegment] and covers ≥ [minSegmentMeters] at
/// [minKmh]..[maxKmh]: running and vehicles are thrown away. Any speed
/// above [vehicleKmh] means you're not walking: the segment is dropped and
/// nothing is learned for [vehicleCooldown] (a car in traffic crawls between
/// bursts).
///
/// Each counted segment moves [kmh] toward its pace by
/// α = 1 − exp(−duration / [tau]), at most [maxShare] per segment.
class WalkCalibrator {
  WalkCalibrator({
    this.kmh = 5.0,
    this.minutes = 0,
    this.maxAccuracy = 15,
    this.anchorMeters = 25,
    this.maxPause = const Duration(seconds: 60),
    this.minSegment = const Duration(seconds: 90),
    this.minSegmentMeters = 100,
    this.chunk = const Duration(minutes: 5),
    this.minKmh = 2.5,
    this.maxKmh = 7.5,
    this.vehicleKmh = 10,
    this.vehicleCooldown = const Duration(minutes: 5),
    this.tau = const Duration(minutes: 45),
    this.maxShare = 0.25,
    this.floorKmh = 3.5,
    this.ceilingKmh = 6.5,
  });

  /// The learned pace, km/h.
  double kmh;

  /// Walking counted so far, minutes (shown in the settings).
  double minutes;

  final double maxAccuracy;

  /// Distance is measured between fixes at least this far apart, so GPS
  /// jitter doesn't add up.
  final double anchorMeters;
  final Duration maxPause;
  final Duration minSegment;
  final double minSegmentMeters;

  /// A long walk is counted every [chunk], so closing the app loses little.
  final Duration chunk;
  final double minKmh, maxKmh, vehicleKmh;
  final Duration vehicleCooldown;
  final Duration tau;
  final double maxShare;
  final double floorKmh, ceilingKmh;

  /// Fixes ≥ [anchorMeters] apart in the current segment's chunk.
  final _anchors = <WalkFix>[];

  /// Minutes of the current segment already counted (for [maxShare]).
  double _segmentMinutes = 0;
  DateTime? _cooldownUntil;

  /// Feeds a fix; [riding] when you've said you're on a vehicle. Returns the
  /// new pace when it changed, null otherwise.
  double? add(WalkFix fix, {bool riding = false}) {
    if (riding || _isVehicle(fix)) {
      if (!riding) _cooldownUntil = fix.time.add(vehicleCooldown);
      _reset();
      return null;
    }
    final until = _cooldownUntil;
    if (until != null && fix.time.isBefore(until)) return null;
    if (fix.accuracy > maxAccuracy) return null;

    if (_anchors.isEmpty) {
      _anchors.add(fix);
      return null;
    }
    final last = _anchors.last;
    if (fix.time.difference(last.time) > maxPause) {
      // A stop: the segment ended at the last anchor.
      final learned = _count(_anchors);
      _reset();
      _anchors.add(fix);
      return learned;
    }
    if (distanceMeters(last.position, fix.position) < anchorMeters) return null;
    _anchors.add(fix);
    if (fix.time.difference(_anchors.first.time) < chunk) return null;
    final learned = _count(_anchors);
    _anchors.removeRange(0, _anchors.length - 1); // the walk goes on from here
    return learned;
  }

  /// Forgets what was learned.
  void reset({double kmh = 5.0}) {
    this.kmh = kmh;
    minutes = 0;
    _reset();
    _cooldownUntil = null;
  }

  void _reset() {
    _anchors.clear();
    _segmentMinutes = 0;
  }

  bool _isVehicle(WalkFix fix) {
    final s = fix.speed;
    if (s != null && s * 3.6 > vehicleKmh) return true;
    if (_anchors.isEmpty || fix.accuracy > maxAccuracy) return false;
    // Without a GPS speed: two good fixes too far apart for their time
    // (some slack for their position error).
    final last = _anchors.last;
    final secs = fix.time.difference(last.time).inMilliseconds / 1000;
    if (secs <= 0 || secs > maxPause.inSeconds) return false; // unknown in between
    final meters = distanceMeters(last.position, fix.position) - fix.accuracy - last.accuracy;
    return meters > 0 && meters / secs * 3.6 > vehicleKmh;
  }

  /// Moves [kmh] toward the pace over [anchors], if it is a walk.
  double? _count(List<WalkFix> anchors) {
    if (anchors.length < 2) return null;
    final elapsed = anchors.last.time.difference(anchors.first.time);
    if (elapsed < minSegment) return null;
    var meters = 0.0;
    for (var i = 1; i < anchors.length; i++) {
      meters += distanceMeters(anchors[i - 1].position, anchors[i].position);
    }
    if (meters < minSegmentMeters) return null;
    final pace = meters / (elapsed.inMilliseconds / 1000) * 3.6;
    if (pace < minKmh || pace > maxKmh) return null;

    minutes += elapsed.inSeconds / 60;
    final capMinutes = -tau.inSeconds / 60 * math.log(1 - maxShare);
    final counted = math.min(elapsed.inSeconds / 60, capMinutes - _segmentMinutes);
    if (counted <= 0) return kmh; // only the minutes change
    _segmentMinutes += counted;
    final alpha = 1 - math.exp(-counted / (tau.inSeconds / 60));
    kmh = (kmh + alpha * (pace - kmh)).clamp(floorKmh, ceilingKmh);
    return kmh;
  }
}
