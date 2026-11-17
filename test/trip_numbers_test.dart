import 'package:flutter_test/flutter_test.dart';
import 'package:roma_transit/backend/trip_numbers.dart';

void main() {
  test('feed of trip and route ids', () {
    expect(feedOf('20261117_15:28_it-trenitalia_0083_10083_0_v_1-21087'), 'it-trenitalia');
    expect(feedOf('it-trenitalia_10083_237bd9c1efe72886'), 'it-trenitalia');
    expect(feedOf('20261117_14:50_it-Lazio-Rome_0#6186-13'), 'it-Lazio-Rome');
    expect(feedOf(null), isNull);
  });

  test('trip number only for listed operators', () {
    const train = '20261117_17:56_it-trenitalia_0083_10083_0_v_1-21087-1DB1-0083';
    expect(rideLabel('REG', '21087', train), 'REG 21087');
    expect(rideLabel('BUS', 'RM200', 'it-trenitalia_70083_x'), 'BUS RM200');
    expect(rideLabel('REG', '', train), 'REG');
    // Rome's buses: trip_short_name is an internal run code.
    expect(rideLabel('64', '18365364', '20261117_14:50_it-Lazio-Rome_1#1-2'), '64');
    expect(showsTripNumber('20261117_14:50_it-Lazio-Rome_1#1-2'), isFalse);
  });
}
