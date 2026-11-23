import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/route_search.dart';

final _t0 = DateTime(2026, 11, 12, 12);
DateTime _m(int min) => _t0.add(Duration(minutes: min));
const _p = LatLng(41.9, 12.5);

/// [rides] consecutive rides filling [start]..[end] (changes = rides - 1).
Itinerary _it(String name, int start, int end, int rides) {
  final step = (end - start) ~/ rides;
  return Itinerary(start: _m(start), end: _m(end), transfers: rides - 1, legs: [
    for (var i = 0; i < rides; i++)
      Leg(
        mode: 'BUS', transit: true, start: _m(start + i * step), end: _m(i == rides - 1 ? end : start + (i + 1) * step),
        fromName: '', toName: '', from: _p, to: _p, points: const [], distanceMeters: 0,
        routeShortName: '$name$i', tripId: '$name$i',
      ),
  ]);
}

List<String> _order(List<Itinerary> its) =>
    RouteSearch(_NoPlanner(), clock: () => _t0).group(its).map((g) => g.signature.split(' › ').first).toList();

void main() {
  const r = kRankPolicy;
  int pen(int tripMin) => r.penalty(Duration(minutes: tripMin)).inMinutes;

  test('penalty per change: max(3, 10%), cap 10, rounded up', () {
    expect(pen(15), 3);
    expect(pen(30), 3);
    expect(pen(45), 5); // 4.5 -> 5
    expect(pen(60), 6);
    expect(pen(90), 9);
    expect(pen(100), 10);
    expect(pen(150), 10); // cap
  });

  test('one fewer change, a little later on a ~30-min trip, ranks first', () {
    // A: 2 changes x 3 = 12:30 -> 12:36. B: 1 change x 4 (3.1 rounded up) = 12:31 -> 12:35.
    expect(_order([_it('A', 0, 30, 3), _it('B', 0, 31, 2)]), ['B0', 'A0']);
    // B at 12:32: 3.2 -> 4, 12:36: a tie, the earlier arrival (A) goes first.
    expect(_order([_it('A', 0, 30, 3), _it('B', 0, 32, 2)]), ['A0', 'B0']);
  });

  test('direct 8 min later on a 60-min trip with 2 changes ranks first', () {
    // A: 13:00 + 2x6 = 13:12. C: 13:08.
    expect(_order([_it('A', 0, 60, 3), _it('C', 0, 68, 1)]), ['C0', 'A0']);
  });

  test('6 min later is too much for one change on a short trip', () {
    // A: 12:30 + 3 = 12:33. D: 12:36.
    expect(_order([_it('A', 0, 30, 2), _it('D', 0, 36, 1)]), ['A0', 'D0']);
  });

  group('arriving by a time: the mirror', () {
    List<RouteGroup> grouped(List<Itinerary> its) =>
        RouteSearch(_NoPlanner(), clock: () => _t0).group(its, when: PlanTime(time: _m(60), arriveBy: true));

    test('the journey that leaves latest comes first', () {
      // A: 12:00 -> 12:30. B: 12:10 -> 12:40. Both arrive by 13:00.
      expect(_order([_it('A', 0, 30, 1), _it('B', 10, 40, 1)]), ['A0', 'B0']); // leaving: arrive first
      expect(grouped([_it('A', 0, 30, 1), _it('B', 10, 40, 1)]).map((g) => g.signature), ['B0', 'A0']);
    });

    test('a change costs as much: leaving a little later with one more change ranks after', () {
      // A direct 12:10 -> 12:40. B with a change 12:12 -> 12:42 (3 min off): 12:09.
      expect(grouped([_it('A', 10, 40, 1), _it('B', 12, 42, 2)]).first.signature, 'A0');
    });

    test('runs of one route: the later one is shown, the earlier a swipe away', () {
      Itinerary run(int start) => Itinerary(start: _m(start), end: _m(start + 20), transfers: 0, legs: [
            Leg(mode: 'BUS', transit: true, start: _m(start), end: _m(start + 20), fromName: '', toName: '',
                from: _p, to: _p, points: const [], distanceMeters: 0, routeShortName: '60', tripId: 'r$start'),
          ]);
      final g = grouped([run(0), run(15), run(30)]).single;
      expect(g.options.map((it) => it.start), [_m(30), _m(15), _m(0)]);
    });

    test('"fastest" is the shortest journey', () {
      // A: 30 min. B: 40 min, leaves later (first in the list).
      final groups = grouped([_it('A', 0, 30, 1), _it('B', 10, 50, 1)]);
      expect(groups.first.signature, 'B0');
      expect(groups.firstWhere((g) => g.tags.contains(RouteTag.fastest)).signature, 'A0');
    });
  });

  test('Fastest tag stays on the earliest arrival', () {
    final groups = RouteSearch(_NoPlanner(), clock: () => _t0).group([_it('A', 0, 30, 3), _it('B', 0, 31, 2)]);
    expect(groups.firstWhere((g) => g.tags.contains(RouteTag.fastest)).signature, startsWith('A0'));
  });
}

class _NoPlanner implements TripPlanner {
  @override
  Future<List<Itinerary>> plan(LatLng from, LatLng to, {PlanOptions options = const PlanOptions()}) async => const [];
}
