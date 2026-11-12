import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/models.dart';
import 'package:roma_transit/backend/trip_variants.dart';

final _t0 = DateTime(2026, 11, 12, 8);
DateTime _m(int min) => _t0.add(Duration(minutes: min));
const _p = LatLng(41.9, 12.5);

Leg _walk(int a, int b, [String to = '']) => Leg(
    mode: 'WALK', transit: false, start: _m(a), end: _m(b), fromName: '', toName: to,
    from: _p, to: _p, points: const [], distanceMeters: 100);
Leg _ride(String line, String trip, int a, int b, {List<LegAlternative> alts = const []}) => Leg(
    mode: 'BUS', transit: true, start: _m(a), end: _m(b), fromName: '', toName: '',
    from: _p, to: _p, points: const [], distanceMeters: 0, routeShortName: line, tripId: trip, alternatives: alts);

void main() {
  // walk 0-4, 88 4-10, walk 10-12, 60 15-40, walk 40-43
  Itinerary base({List<LegAlternative> first = const [], List<LegAlternative> second = const []}) => Itinerary(
        start: _m(0),
        end: _m(43),
        transfers: 1,
        legs: [_walk(0, 4), _ride('88', 'a', 4, 10, alts: first), _walk(10, 12), _ride('60', 'b', 15, 40, alts: second), _walk(40, 43)],
      );

  test('variant 0 reproduces the original trip', () {
    final v = TripVariants(clock: () => _t0, base());
    expect(v.slotCount, 2);
    expect(v.current.legs.map((l) => l.routeShortName ?? 'walk'), ['walk', '88', 'walk', '60', 'walk']);
    expect(v.current.start, _m(0));
    expect(v.current.end, _m(43));
  });

  test('swapping the first ride re-times the walks and the departure', () {
    final alt3 = LegAlternative([_walk(1, 6), _ride('3', 'c', 6, 11), _walk(11, 14)]);
    final v = TripVariants(clock: () => _t0, base(first: [alt3]));
    expect(v.variantCount(0), 2);
    expect(v.choose(0, 1), isTrue);
    final legs = v.current.legs;
    expect(legs.map((l) => l.routeShortName ?? 'walk'), ['walk', '3', 'walk', '60', 'walk']);
    expect(legs.first.start, _m(1)); // leave when the walk to the 3 starts (5 min before 6)
    expect(legs[2].start, _m(11)); // transfer walk hangs off the 3's arrival
    expect(legs[2].end, _m(14));
    expect(v.current.end, _m(43));
    expect(v.slotOfLeg(1), 0);
    expect(v.slotOfLeg(3), 1);
  });

  test('swapping the last ride moves the arrival', () {
    final alt = LegAlternative([_walk(10, 13), _ride('61', 'd', 14, 36), _walk(36, 41)]);
    final v = TripVariants(clock: () => _t0, base(second: [alt]));
    v.choose(1, 1);
    expect(v.current.legs.map((l) => l.routeShortName ?? 'walk'), ['walk', '88', 'walk', '61', 'walk']);
    expect(v.current.end, _m(41));
  });

  test('incompatible combination resets the other slot', () {
    // 3 arrives 14, transfer walk 3 min -> 17: too late for the alt 61 at 15.
    final late3 = LegAlternative([_walk(4, 6), _ride('3', 'c', 7, 14), _walk(14, 17)]);
    final early61 = LegAlternative([_walk(10, 12), _ride('61', 'd', 13, 35), _walk(35, 38)]);
    final v = TripVariants(clock: () => _t0, base(first: [late3], second: [early61]));
    expect(v.choose(1, 1), isTrue);
    expect(v.choose(0, 1), isFalse); // can't keep the 61
    expect(v.choiceOf(1), 0);
    expect(v.current.legs.map((l) => l.routeShortName ?? 'walk'), ['walk', '3', 'walk', '60', 'walk']);
  });

  test('alternatives that have already left are not offered', () {
    // Now is 6: the 3 at 5 has left, the 3 at 7 needs a 2-min walk from 5.
    final gone = LegAlternative([_walk(3, 5), _ride('3', 'c', 5, 11), _walk(11, 14)]);
    final missed = LegAlternative([_walk(5, 7), _ride('3', 'd', 7, 12), _walk(12, 14)]);
    final ok = LegAlternative([_walk(7, 9), _ride('3', 'e', 9, 12), _walk(12, 14)]);
    final v = TripVariants(base(first: [gone, missed, ok]), clock: () => _m(6));
    expect(v.variantCount(0), 3); // original (kept as the default), 7 with 1 min slack, 9
    expect(v.rideOf(0, 2).tripId, 'e');
  });

  test('alternative identical to the chosen ride is not offered twice', () {
    final same = LegAlternative([_walk(0, 4), _ride('88', 'a', 4, 10), _walk(10, 12)]);
    expect(TripVariants(clock: () => _t0, base(first: [same])).variantCount(0), 1);
  });
}
