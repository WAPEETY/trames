import 'package:flutter_test/flutter_test.dart';
import 'package:roma_transit/backend/delay.dart';

void main() {
  const p = kDelayPolicy;
  int m(num minutes) => (minutes * 60).round();
  DelayLevel c(num lateMin, {int? tripMin, bool live = true}) =>
      p.classify(m(lateMin), reference: tripMin == null ? null : Duration(minutes: tripMin), live: live);

  test('not live or missing is unknown', () {
    expect(c(5, live: false), DelayLevel.unknown);
    expect(p.classify(null), DelayLevel.unknown);
  });

  test('implausible feed values are ignored', () {
    expect(p.classify(-86276), DelayLevel.unknown);
    expect(c(-11), DelayLevel.unknown);
    expect(c(91), DelayLevel.unknown);
  });

  test('short trip: floors apply (5 / 10 min)', () {
    expect(c(5, tripMin: 15), DelayLevel.onTime);
    expect(c(6, tripMin: 15), DelayLevel.minor);
    expect(c(10, tripMin: 15), DelayLevel.minor);
    expect(c(11, tripMin: 15), DelayLevel.major);
  });

  test('45-minute trip: 20% / 40%', () {
    expect(c(9, tripMin: 45), DelayLevel.onTime);
    expect(c(10, tripMin: 45), DelayLevel.minor);
    expect(c(18, tripMin: 45), DelayLevel.minor);
    expect(c(19, tripMin: 45), DelayLevel.major);
  });

  test('long trip: capped at 15 / 30 min', () {
    expect(c(15, tripMin: 90), DelayLevel.onTime);
    expect(c(16, tripMin: 90), DelayLevel.minor);
    expect(c(30, tripMin: 90), DelayLevel.minor);
    expect(c(31, tripMin: 90), DelayLevel.major);
  });

  test('no reference: absolute floors only', () {
    expect(c(5), DelayLevel.onTime);
    expect(c(8), DelayLevel.minor);
    expect(c(11), DelayLevel.major);
  });

  test('early is always on time', () {
    expect(c(-0.5, tripMin: 60), DelayLevel.onTime);
    expect(c(-3, tripMin: 10), DelayLevel.onTime);
    expect(c(-9), DelayLevel.onTime);
  });

  test('describeDelay', () {
    expect(describeDelay(null), 'scheduled');
    expect(describeDelay(20), 'on time');
    expect(describeDelay(180), '3 min late');
    expect(describeDelay(-60), '1 min early');
  });
}
