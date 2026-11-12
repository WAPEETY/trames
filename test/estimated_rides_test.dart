import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/estimated_rides.dart';
import 'package:roma_transit/backend/models.dart';
import 'package:roma_transit/backend/trip_variants.dart';

final _t0 = DateTime(2026, 11, 13, 8);
DateTime _m(int min) => _t0.add(Duration(minutes: min));
const _p = LatLng(41.9, 12.5);

Leg _walk(int a, int b) => Leg(
    mode: 'WALK', transit: false, start: _m(a), end: _m(b), fromName: '', toName: '',
    from: _p, to: _p, points: const [], distanceMeters: 100);
Leg _ride(String line, String trip, int a, int b, {List<LegAlternative> alts = const []}) => Leg(
    mode: 'BUS', transit: true, start: _m(a), end: _m(b), fromName: '', toName: '',
    from: _p, to: _p, points: const [], distanceMeters: 0, routeShortName: line, tripId: trip, alternatives: alts);

// walk 0-4, 88 4-10, walk 10-12, 60 15-40, walk 40-43
Itinerary _trip({List<LegAlternative> second = const []}) => Itinerary(
      start: _m(0),
      end: _m(43),
      transfers: 1,
      legs: [_walk(0, 4), _ride('88', 'a', 4, 10), _walk(10, 12), _ride('60', 'b', 15, 40, alts: second), _walk(40, 43)],
    );

ReturnEstimate _late(int min) => ReturnEstimate(Certainty.estimated, delay: Duration(minutes: min));

void main() {
  Itinerary apply(Itinerary it, Map<String, ReturnEstimate> e) => applyEstimatedRides(it, e, clock: () => _t0);
  String rides(Itinerary it) => it.transitLegs.map((l) => '${l.routeShortName}@${l.start.difference(_t0).inMinutes}').join(' ');

  test('no estimated ride: unchanged', () {
    final it = _trip();
    expect(apply(it, {'a': const ReturnEstimate(Certainty.returning)}), same(it));
  });

  test('late first ride that still connects: leave later, same arrival', () {
    final r = apply(_trip(), {'a': _late(3)});
    expect(rides(r), '88@7 60@15');
    expect(r.start, _m(3));
    expect(r.end, _m(43));
    expect(r.missedConnection, isFalse);
  });

  test('connection broken: the next bus that works is taken', () {
    final later60 = LegAlternative([_walk(10, 12), _ride('60', 'c', 25, 50), _walk(50, 53)]);
    final r = apply(_trip(second: [later60]), {'a': _late(8)}); // 88 arrives 18, walk to 20 > 15
    expect(rides(r), '88@12 60@25');
    expect(r.end, _m(53));
    expect(r.missedConnection, isFalse);
    // The trip view reopens on the same buses.
    final again = TripVariants(r.base!, choices: r.rideChoices, clock: () => _t0).current;
    expect(rides(again), '88@12 60@25');
  });

  test('no bus makes the connection: flagged', () {
    final r = apply(_trip(), {'a': _late(8)});
    expect(r.missedConnection, isTrue);
    expect(rides(r), '88@12 60@15');
  });

  test('late last ride: arrival moves', () {
    final r = apply(_trip(), {'b': _late(6)});
    expect(rides(r), '88@4 60@21');
    expect(r.end, _m(49));
  });
}
