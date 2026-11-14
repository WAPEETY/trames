import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/walk_calibrator.dart';

final _t0 = DateTime(2026, 11, 14, 17);
const _metersPerDegree = 111195.0;

/// Fixes every [every] while moving north at [kmh] for [duration], starting
/// [at] meters north of the origin at time [from].
List<WalkFix> _walk(
  double kmh,
  Duration duration, {
  Duration from = Duration.zero,
  double at = 0,
  Duration every = const Duration(seconds: 5),
  double accuracy = 5,
  bool reportSpeed = true,
}) {
  final ms = kmh / 3.6;
  return [
    for (var s = 0; s <= duration.inSeconds; s += every.inSeconds)
      WalkFix(
        position: LatLng(41.9 + (at + ms * s) / _metersPerDegree, 12.5),
        time: _t0.add(from + Duration(seconds: s)),
        accuracy: accuracy,
        speed: reportSpeed ? ms : null,
      ),
  ];
}

/// Feeds [fixes]; returns the last pace learned (null if none).
double? _feed(WalkCalibrator c, Iterable<WalkFix> fixes, {bool riding = false}) {
  double? last;
  for (final f in fixes) {
    last = c.add(f, riding: riding) ?? last;
  }
  return last;
}

/// A fix far away much later: ends any segment in progress.
WalkFix _later(Duration at) =>
    WalkFix(position: const LatLng(42.5, 12.5), time: _t0.add(at), accuracy: 5, speed: 0);

void main() {
  test('a walk moves the pace toward it, by 1 - exp(-minutes / 45)', () {
    final c = WalkCalibrator();
    _feed(c, _walk(4.0, const Duration(minutes: 3)));
    expect(c.add(_later(const Duration(minutes: 10))), isNotNull);
    // ~3 min at ~4 km/h (anchors every 25 m: a bit under 3 min).
    expect(c.kmh, lessThan(5.0));
    expect(c.kmh, greaterThan(4.9));
    expect(c.minutes, closeTo(3, 0.2));
  });

  test('a long walk is counted every 5 min but moves the pace at most 25%', () {
    final c = WalkCalibrator(ceilingKmh: 10);
    final learned = _feed(c, _walk(7.0, const Duration(minutes: 60)));
    expect(learned, isNotNull); // counted while walking, not only at the end
    expect(c.kmh, closeTo(5.0 + 0.25 * 2.0, 0.02));
    expect(c.minutes, closeTo(60, 1));
  });

  test('running is thrown away', () {
    final c = WalkCalibrator();
    _feed(c, _walk(9.0, const Duration(minutes: 10)));
    c.add(_later(const Duration(minutes: 20)));
    expect(c.kmh, 5.0);
    expect(c.minutes, 0);
  });

  test('faster than 10 km/h: a vehicle; nothing is learned for 5 min', () {
    final c = WalkCalibrator();
    // A car crawls at walking pace, with one burst.
    _feed(c, [
      ..._walk(5.0, const Duration(minutes: 2)),
      ..._walk(25.0, const Duration(seconds: 10), from: const Duration(minutes: 2, seconds: 5), at: 170),
      ..._walk(4.0, const Duration(minutes: 4), from: const Duration(minutes: 2, seconds: 20), at: 250),
    ]);
    c.add(_later(const Duration(minutes: 30)));
    expect(c.kmh, 5.0);
    expect(c.minutes, 0);
  });

  test('without a GPS speed, positions too far apart for their time are a vehicle', () {
    final c = WalkCalibrator();
    _feed(c, _walk(40.0, const Duration(minutes: 1), reportSpeed: false));
    _feed(c, _walk(4.0, const Duration(minutes: 3), from: const Duration(minutes: 1, seconds: 5), at: 700, reportSpeed: false));
    c.add(_later(const Duration(minutes: 30)));
    expect(c.minutes, 0);
  });

  test('on board, nothing is learned', () {
    final c = WalkCalibrator();
    _feed(c, _walk(5.0, const Duration(minutes: 6)), riding: true);
    expect(c.minutes, 0);
  });

  test('a stop over 60 s ends the walk there; shorter ones (lights) count in the pace', () {
    final c = WalkCalibrator(ceilingKmh: 10);
    // 2 min at 6 km/h, a 40 s light, 2 min more: 400 m in 4:40.
    _feed(c, [
      ..._walk(6.0, const Duration(minutes: 2)),
      ..._walk(6.0, const Duration(minutes: 2), from: const Duration(minutes: 2, seconds: 40), at: 200),
    ]);
    c.add(_later(const Duration(minutes: 10)));
    final paceKmh = 400 / 280 * 3.6; // ~5.1
    expect(c.kmh, closeTo(5.0 + (1 - 0.902) * (paceKmh - 5.0), 0.05));
    expect(c.minutes, closeTo(4.6, 0.2));
  });

  test('too short, or imprecise GPS: nothing learned', () {
    final c = WalkCalibrator();
    _feed(c, _walk(5.0, const Duration(seconds: 60)));
    c.add(_later(const Duration(minutes: 5)));
    _feed(c, _walk(5.0, const Duration(minutes: 4), accuracy: 30, from: const Duration(minutes: 10)));
    c.add(_later(const Duration(minutes: 20)));
    expect(c.minutes, 0);
  });

  test('the pace stays within 3.5..6.5 km/h; reset forgets it', () {
    final c = WalkCalibrator(kmh: 6.4);
    _feed(c, _walk(7.4, const Duration(minutes: 60)));
    expect(c.kmh, 6.5);
    c.reset();
    expect((c.kmh, c.minutes), (5.0, 0));
  });
}
