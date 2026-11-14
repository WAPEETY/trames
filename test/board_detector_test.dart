import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/board_detector.dart';

final _t0 = DateTime(2026, 11, 14, 15);
DateTime _s(int sec) => _t0.add(Duration(seconds: sec));
// ~111 m per 0.001° of latitude.
LatLng _at(double m) => LatLng(41.9 + m / 111000, 12.5);

void main() {
  test('asks once the same bus stays near while you move with it', () {
    final d = BoardDetector();
    expect(d.update(_at(0), {'341': _at(20)}, _s(0)), isNull);
    expect(d.update(_at(60), {'341': _at(90)}, _s(10)), isNull); // too soon
    expect(d.update(_at(150), {'341': _at(170)}, _s(25)), '341');
  });

  test('standing at a stop while a bus waits: no', () {
    final d = BoardDetector();
    d.update(_at(0), {'341': _at(10)}, _s(0));
    expect(d.update(_at(5), {'341': _at(10)}, _s(40)), isNull);
  });

  test('a bus passing by: no (it does not stay near)', () {
    final d = BoardDetector();
    d.update(_at(0), {'341': _at(50)}, _s(0));
    expect(d.update(_at(120), {'341': _at(600)}, _s(25)), isNull);
  });

  test('"no" snoozes that bus for a minute; another bus can still be asked about', () {
    final d = BoardDetector();
    d.update(_at(0), {'341': _at(20), '60': _at(40)}, _s(0));
    expect(d.update(_at(150), {'341': _at(170), '60': _at(190)}, _s(25)), '341');
    d.dismiss('341', _s(25));
    expect(d.update(_at(200), {'341': _at(210), '60': _at(230)}, _s(30)), isNull); // 60 starts now
    expect(d.update(_at(350), {'341': _at(360), '60': _at(370)}, _s(55)), '60');
    // After a minute the 341 can be asked about again.
    final d2 = BoardDetector()..dismiss('341', _s(0));
    d2.update(_at(0), {'341': _at(10)}, _s(61));
    expect(d2.update(_at(150), {'341': _at(160)}, _s(85)), '341');
  });
}
