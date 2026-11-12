import 'package:flutter_test/flutter_test.dart';
import 'package:roma_transit/backend/models.dart';
import 'package:roma_transit/backend/motis.dart';

void main() {
  test('MOTIS trip ids reduce to the raw GTFS trip_id', () {
    expect(MotisClient.rawTripId('20261112_04:45_it-Lazio-Rome_0#1054-2'), '0#1054-2');
    expect(MotisClient.rawTripId('20261111_29:00_it-Lazio-Rome_0#4203-23'), '0#4203-23');
    expect(MotisClient.rawTripId('weird'), 'weird');
    expect(MotisClient.rawTripId(null), isNull);
  });

  test('polyline precision 6', () {
    // (38.5, -120.2) encoded at precision 6
    final p = decodePolyline('_izlhA~rlgdF', precision: 6);
    expect(p.single.latitude, closeTo(38.5, 1e-6));
    expect(p.single.longitude, closeTo(-120.2, 1e-6));
  });
}
