import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/route_search.dart';
import 'package:roma_transit/backend/trip_variants.dart';

final _t0 = DateTime(2026, 11, 12, 8);
DateTime _m(num min) => _t0.add(Duration(seconds: (min * 60).round()));
DateTime _clock() => _t0;

// Stops, a few hundred metres apart (all well under the 3 km cap).
const _o = LatLng(41.900, 12.500); // origin
const _a = LatLng(41.901, 12.501); // board ride 1
const _b = LatLng(41.903, 12.503); // alight ride 1
const _c = LatLng(41.9035, 12.5035); // board ride 2
const _d = LatLng(41.910, 12.510); // alight ride 2
const _e = LatLng(41.911, 12.511); // destination

Leg _walk(LatLng f, LatLng t, num a, num b) => Leg(
    mode: 'WALK', transit: false, start: _m(a), end: _m(b), fromName: 'w', toName: 'w',
    from: f, to: t, points: [f, t], distanceMeters: 100);
Leg _ride(String line, String trip, LatLng f, LatLng t, num a, num b) => Leg(
    mode: 'BUS', transit: true, start: _m(a), end: _m(b), fromName: line, toName: line,
    from: f, to: t, points: [f, t], distanceMeters: 0, routeShortName: line, tripId: trip);

/// walk 0-4, 19BUS 4-6 (2-min ride), walk 6-8, 71 12-30, walk 30-33
/// ([at] minutes later for a journey planned for later).
Itinerary _trip({num at = 0}) => Itinerary(start: _m(at), end: _m(at + 33), transfers: 1, legs: [
      _walk(_o, _a, at + 0, at + 4),
      _ride('19BUS', 'r1', _a, _b, at + 4, at + 6),
      _walk(_b, _c, at + 6, at + 8),
      _ride('71', 'r2', _c, _d, at + 12, at + 30),
      _walk(_d, _e, at + 30, at + 33),
    ]);

class _FakeWalks implements WalkRouter {
  _FakeWalks(this.minutes);
  final Map<String, num> minutes; // walkKey -> minutes
  int calls = 0;
  @override
  Future<WalkRoute?> walk(LatLng from, LatLng to) async {
    calls++;
    final m = minutes[walkKey(from, to)];
    return m == null
        ? null
        : WalkRoute(duration: Duration(seconds: (m * 60).round()), distanceMeters: m * 80, points: [from, _c, to]);
  }
}

Future<WalkCache> _cache(Map<String, num> minutes) async {
  final c = WalkCache(_FakeWalks(minutes));
  await c.fetch([(_o, _c), (_b, _e), (_o, _e)], max: 10);
  return c;
}

List<String> _shape(Itinerary it) => [for (final l in it.legs) l.transit ? l.routeShortName! : 'walk'];

void main() {
  hiddenRideTests();
  test('every ride gets a walk option after its ride variants', () async {
    final v = TripVariants(_trip(), walks: await _cache({}), clock: _clock);
    expect(v.variantCount(0), 2);
    expect(v.walkIndex(0), 1);
    expect(v.isWalk(0, 1), isTrue);
    expect(_shape(v.current), ['walk', '19BUS', 'walk', '71', 'walk']);
  });

  test('walking a ride merges it with the walks around it into one walk', () async {
    final v = TripVariants(_trip(), walks: await _cache({walkKey(_o, _c): 9}), clock: _clock);
    expect(v.choose(0, v.walkIndex(0)!), isTrue);
    final legs = v.current.legs;
    expect(_shape(v.current), ['walk', '71', 'walk']);
    expect(legs[0].from, _o);
    expect(legs[0].to, _c); // one street route origin -> boarding stop of the 71
    expect(legs[0].points, [_o, _c, _c]); // the fetched route, not glued pieces
    expect(legs[0].end, _m(12)); // arrive when the 71 leaves
    expect(legs[0].start, _m(3));
    expect(v.slotOfLeg(0), 0); // the walk is swipeable back to the bus
    expect(v.current.walkSlots, {0});
    expect(v.current.walkOptions, {0: ['19BUS']}); // shown as "🚶 9 ╱ 19BUS"
  });

  test('picking the bus again brings back its own walks, re-timed', () async {
    final v = TripVariants(_trip(), walks: await _cache({walkKey(_o, _c): 9}), clock: _clock);
    v.choose(0, v.walkIndex(0)!);
    v.choose(0, 0);
    final legs = v.current.legs;
    expect(_shape(v.current), ['walk', '19BUS', 'walk', '71', 'walk']);
    expect(legs[0].end, _m(4)); // walk to the stop ends when the bus leaves
    expect(legs[2].start, _m(6)); // transfer walk starts when it arrives
    expect(v.current.walkSlots, isEmpty);
  });

  test('two walked rides become a single walk from start to finish', () async {
    final cache = WalkCache(_FakeWalks({walkKey(_o, _c): 9, walkKey(_b, _e): 15, walkKey(_o, _e): 22}));
    await cache.fetch([(_o, _c), (_b, _e)]);
    final v = TripVariants(_trip(), walks: cache, clock: _clock);
    v.choose(0, v.walkIndex(0)!);
    v.choose(1, v.walkIndex(1)!);
    // origin -> destination not fetched yet: estimated and reported missing
    expect(_shape(v.current), ['walk']);
    expect(v.missingWalks.single, (_o, _e));
    await cache.fetch(v.missingWalks);
    v.refresh();
    expect(v.missingWalks, isEmpty);
    expect(v.current.legs.single.from, _o);
    expect(v.current.legs.single.to, _e);
    expect(v.current.start, _t0); // walking the whole way: leave now
    expect(v.current.duration, const Duration(minutes: 22));
  });

  test('a walk that would miss the next ride is refused', () async {
    // 15 min from origin to the 71 stop: you'd have to leave before now.
    final v = TripVariants(_trip(), walks: await _cache({walkKey(_o, _c): 15}), clock: _clock);
    v.choose(0, v.walkIndex(0)!);
    expect(v.feasible, isFalse);
  });

  group('route search walk rules', () {
    Future<List<RouteGroup>> search(Map<String, num> walkMinutes, Itinerary trip) => RouteSearch(
          _OnePlanner([trip]),
          profiles: const [PlanProfile('default', PlanOptions())],
          walks: WalkCache(_FakeWalks(walkMinutes)),
          clock: _clock,
        ).search(_o, _e);

    test('rule 1a: a 2-minute ride is walked when walking is at most 2 min later', () async {
      // walk origin -> 71 stop: 9 min from now (08:09), bus way gets there 08:08.
      final groups = await search({walkKey(_o, _c): 9, walkKey(_b, _e): 40}, _trip());
      final it = groups.single.best;
      expect(_shape(it), ['walk', '71', 'walk']);
      expect(it.walkSlots, {0});
      expect(_shape(it.base!), ['walk', '19BUS', 'walk', '71', 'walk']); // bus kept for the swipe
    });

    test('a short ride is kept when walking is much slower', () async {
      final groups = await search({walkKey(_o, _c): 11.5, walkKey(_b, _e): 40}, _trip());
      expect(_shape(groups.single.best), ['walk', '19BUS', 'walk', '71', 'walk']);
    });

    test('rule 1b: a long ride is walked when, counting the wait, walking arrives first', () async {
      // 71: wait 08:08 -> 08:12, ride 18 min, walk on: destination 08:33.
      // Walking from the 19BUS stop (08:06) takes 25 min: 08:31.
      final groups = await search({walkKey(_o, _c): 30, walkKey(_b, _e): 25}, _trip());
      final it = groups.single.best;
      expect(_shape(it), ['walk', '19BUS', 'walk']);
      expect(it.end, _m(31));
    });
  });

  group('planned for another time (now 08:00)', () {
    // The trip leaves at 10:00: walk 10:00-10:04, 19BUS 10:04-10:06, ...
    final later = _trip(at: 120);

    Future<TripVariants> walkedWhole(PlanTime when) async {
      final cache = WalkCache(_FakeWalks({walkKey(_o, _c): 9, walkKey(_b, _e): 15, walkKey(_o, _e): 22}));
      await cache.fetch([(_o, _c), (_b, _e), (_o, _e)]);
      final v = TripVariants(later, walks: cache, clock: _clock, when: when);
      v.choose(0, v.walkIndex(0)!);
      v.choose(1, v.walkIndex(1)!);
      return v;
    }

    test('walking the whole way leaves at the chosen departure, not now', () async {
      final v = await walkedWhole(PlanTime(time: _m(120)));
      expect(_shape(v.current), ['walk']);
      expect(v.current.start, _m(120));
      expect(v.feasible, isTrue);
    });

    test('arriving by a time, walking the whole way arrives when the bus would', () async {
      final v = await walkedWhole(PlanTime(time: _m(160), arriveBy: true));
      expect(_shape(v.current), ['walk']);
      expect(v.current.end, _m(153));
      expect(v.current.start, _m(131));
    });

    Future<List<RouteGroup>> search(Map<String, num> walkMinutes, PlanTime when) => RouteSearch(
          _OnePlanner([later]),
          profiles: const [PlanProfile('default', PlanOptions())],
          walks: WalkCache(_FakeWalks(walkMinutes)),
          clock: _clock,
        ).search(_o, _e, when: when);

    test('a short first ride is kept when walking from the departure is much slower', () async {
      // From 10:00, 11.5 min to the 71 stop: 10:11:30, the bus way 10:08.
      final groups = await search({walkKey(_o, _c): 11.5, walkKey(_b, _e): 40}, PlanTime(time: _m(120)));
      expect(_shape(groups.single.best), ['walk', '19BUS', 'walk', '71', 'walk']);
    });

    test('a short first ride is still walked when walking from the departure is about as fast', () async {
      final groups = await search({walkKey(_o, _c): 9, walkKey(_b, _e): 40}, PlanTime(time: _m(120)));
      expect(_shape(groups.single.best), ['walk', '71', 'walk']);
    });

    test('arriving by a time: compared from when the journey sets off, no waiting', () async {
      final kept = await search({walkKey(_o, _c): 11.5, walkKey(_b, _e): 40}, PlanTime(time: _m(160), arriveBy: true));
      expect(_shape(kept.single.best), ['walk', '19BUS', 'walk', '71', 'walk']);
      final walked = await search({walkKey(_o, _c): 9, walkKey(_b, _e): 40}, PlanTime(time: _m(160), arriveBy: true));
      expect(_shape(walked.single.best), ['walk', '71', 'walk']);
    });
  });

  test('rule 2: walking the whole way is suggested first when about as fast', () async {
    // Transit arrives 08:33. A 24-min walk (08:24) is suggested first.
    final walkOnly = Itinerary(start: _m(0), end: _m(24), transfers: 0, legs: [_walk(_o, _e, 0, 24)]);
    final groups = RouteSearch(_OnePlanner(const []), clock: _clock).group([_trip(), walkOnly]);
    expect(groups.first.isWalk, isTrue);
    expect(groups.first.tags, contains(RouteTag.onFoot));
    // 28 min of walking is over the 25-min limit, even though it arrives first.
    final long = Itinerary(start: _m(0), end: _m(28), transfers: 0, legs: [_walk(_o, _e, 0, 28)]);
    final g2 = RouteSearch(_OnePlanner(const []), clock: _clock).group([_trip(), long]);
    expect(g2.firstWhere((g) => g.isWalk).tags, isNot(contains(RouteTag.onFoot)));
  });
}

void hiddenRideTests() {
  // walk 0-4, 19BUS 4-5 (1-min ride: hidden), walk 5-8, 71 12-30, walk 30-33
  Itinerary oneMinute({List<LegAlternative> alts = const []}) => Itinerary(start: _m(0), end: _m(33), transfers: 1, legs: [
        _walk(_o, _a, 0, 4),
        Leg(mode: 'BUS', transit: true, start: _m(4), end: _m(5), fromName: '19BUS', toName: '19BUS', from: _a, to: _b,
            points: [_a, _b], distanceMeters: 0, routeShortName: '19BUS', tripId: 'r1', alternatives: alts),
        _walk(_b, _c, 5, 8),
        _ride('71', 'r2', _c, _d, 12, 30),
        _walk(_d, _e, 30, 33),
      ]);
  final other = LegAlternative([_walk(_o, _a, 1, 3), _ride('492', 'r3', _a, _b, 3, 7), _walk(_b, _c, 7, 9)]);
  final tooShortAlt = LegAlternative([_walk(_o, _a, 2, 4), _ride('3NAV', 'r4', _a, _b, 4, 5), _walk(_b, _c, 5, 8)]);

  group('rides of 1 minute or less are hidden', () {
    test('default to walking when it fits', () async {
      final v = TripVariants(oneMinute(), walks: await _cache({walkKey(_o, _c): 9}), clock: _clock);
      expect(v.hasHidden, isTrue);
      expect(_shape(v.current), ['walk', '71', 'walk']);
      expect(v.variantCount(0), 1); // only walking: the 1-min ride isn't offered
      expect(v.current.walkOptions, isEmpty); // no bus option to show next to the walk
    });

    test('walked leg lists the other buses, never the 1-min ones', () async {
      final v = TripVariants(oneMinute(alts: [tooShortAlt, other]), walks: await _cache({walkKey(_o, _c): 9}), clock: _clock);
      expect(_shape(v.current), ['walk', '71', 'walk']);
      expect(v.current.walkOptions, {0: ['492']}); // 19BUS and 3NAV (1 min) hidden
    });

    test('default to another ride when walking does not fit; short alternatives are hidden too', () async {
      final v = TripVariants(oneMinute(alts: [tooShortAlt, other]), walks: await _cache({walkKey(_o, _c): 15}), clock: _clock);
      expect(_shape(v.current), ['walk', '492', 'walk', '71', 'walk']);
      expect(v.variantCount(0), 2); // 492 + walking; 19BUS and 3NAV (1 min) hidden
    });

    test('search drops an itinerary whose 1-min ride cannot be replaced', () async {
      final groups = await RouteSearch(
        _OnePlanner([oneMinute()]),
        profiles: const [PlanProfile('default', PlanOptions())],
        walks: WalkCache(_FakeWalks({walkKey(_o, _c): 15})), // too slow to make the 71
        clock: _clock,
      ).search(_o, _e);
      expect(groups, isEmpty);
    });

    test('search shows the walked version instead of the 1-min ride', () async {
      final groups = await RouteSearch(
        _OnePlanner([oneMinute()]),
        profiles: const [PlanProfile('default', PlanOptions())],
        walks: WalkCache(_FakeWalks({walkKey(_o, _c): 11, walkKey(_b, _e): 40})), // walking 3 min later: still forced
        clock: _clock,
      ).search(_o, _e);
      expect(_shape(groups.single.best), ['walk', '71', 'walk']);
    });
  });
}

class _OnePlanner implements TripPlanner {
  _OnePlanner(this.result);
  final List<Itinerary> result;
  @override
  Future<List<Itinerary>> plan(LatLng from, LatLng to, {PlanOptions options = const PlanOptions()}) async => result;
}
