import 'package:maplibre_gl/maplibre_gl.dart';

import 'backend.dart';
import 'trip_variants.dart';
import 'walk_rules.dart';

/// One way of asking the planner. Several profiles run in parallel and their
/// results are merged, which surfaces routes a single search drops (a planner
/// keeps only the best trade-offs, so "211 › MEB" at five times can hide a
/// "450 › MEB" that is only slightly worse).
class PlanProfile {
  const PlanProfile(this.id, this.options);
  final String id;
  final PlanOptions options;
}

const kDefaultProfiles = [
  PlanProfile('default', PlanOptions()),
  PlanProfile('fewer-changes', PlanOptions(maxTransfers: 1)),
  PlanProfile('less-walking', PlanOptions(maxWalkMinutes: 10)),
];

/// How much a change costs when ordering routes: routes are ranked by
/// arrival + changes × [penalty], so one fewer change can win while arriving
/// a little later. Scaled by trip length like the delay rules. (A settings
/// page may let users tune this later.)
class RankPolicy {
  const RankPolicy({
    this.changeFloor = const Duration(minutes: 3),
    this.changeShare = 0.10,
    this.changeCap = const Duration(minutes: 10),
  });

  final Duration changeFloor;
  final double changeShare;

  /// Upper bound of the penalty; null: none.
  final Duration? changeCap;

  /// max(floor, share × trip), capped, rounded up to a whole minute.
  Duration penalty(Duration trip) {
    var secs = trip.inSeconds * changeShare;
    if (secs < changeFloor.inSeconds) secs = changeFloor.inSeconds.toDouble();
    final cap = changeCap;
    if (cap != null && secs > cap.inSeconds) secs = cap.inSeconds.toDouble();
    return Duration(minutes: (secs / 60).ceil());
  }

  /// Ranking time of [it]: its arrival plus the cost of its changes.
  DateTime score(Itinerary it) => it.end.add(penalty(it.duration) * it.transfers);
}

const kRankPolicy = RankPolicy();

enum RouteTag { fastest, fewestChanges, leastWalking, onFoot, stayOnBoard }

/// All departures of one line sequence, earliest arrival first.
class RouteGroup {
  RouteGroup(this.signature, this.options);
  final String signature;
  final List<Itinerary> options;
  final Set<RouteTag> tags = {};

  Itinerary get best => options.first;

  /// The first vehicle to catch has real-time data: the departure you plan
  /// around is a live prediction, not just the timetable.
  ///
  /// Metro-only routes count as live too: Rome's metro has no real-time feed,
  /// but it runs on frequent, reliable headways.
  bool get isLive {
    final rides = best.transitLegs;
    if (rides.isEmpty) return false;
    return rides.first.realtime || rides.every((l) => l.mode == 'SUBWAY');
  }

  /// Walking the whole way.
  bool get isWalk => best.walkOnly;

  /// Under "show more": staying on one of its buses takes you there about
  /// as soon (see [Itinerary.hiddenBecause]).
  StayOnReason? get hiddenBecause => best.hiddenBecause;
}

class RouteSearch {
  RouteSearch(
    this.planner, {
    this.profiles = kDefaultProfiles,
    this.maxPerGroup = 4,
    this.walks,
    this.policy = kWalkPolicy,
    this.rank = kRankPolicy,
    this.stayOn = kStayOnPolicy,
    this.trips,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final TripPlanner planner;
  final List<PlanProfile> profiles;
  final int maxPerGroup;

  /// Walking routes; without them no ride is replaced by walking.
  final WalkCache? walks;
  final WalkPolicy policy;
  final RankPolicy rank;

  /// When getting off a vehicle you ride is worth it (rule 2, see
  /// [checkStayingOn]).
  final StayOnPolicy stayOn;

  /// Where runs go, for rule 2; without it nothing is put under "show more".
  final TripDetails? trips;
  final DateTime Function() _clock;

  /// Journeys for someone riding [ride] now (needs an [OnBoardPlanner]):
  /// every journey starts on board. Staying on comes first; getting off is
  /// listed normally only when it clearly pays (rule 2, as for any ride of
  /// any journey). [live] is Tramite's view of the ride, when it covers it:
  /// where the bus really is and its times (see [OnBoardTrip]). Throws
  /// [OnBoardTripOver] when the ride has no stops left.
  Future<List<RouteGroup>> searchOnBoard(OnBoardRide ride, LatLng to, {String toName = '', TramiteTrip? live}) async {
    final TripPlanner p = planner;
    if (p is! OnBoardPlanner) throw UnsupportedError('This planner cannot plan from a vehicle');
    final onBoard = p as OnBoardPlanner;
    final trip = OnBoardTrip(ride, await onBoard.liveTrip(ride.backendTripId), now: _clock(), live: live);
    if (trip.remaining.isEmpty) throw const OnBoardTripOver();
    final cache = walks;
    final stay = cache == null
        ? Future<Itinerary?>.value()
        : stayOnBoard(trip, to, cache, toName: toName).catchError((Object _) => null);
    Object? firstError;
    final batches = await Future.wait(profiles.map((pr) async {
      try {
        return await onBoard.planOnBoard(trip, to, options: pr.options);
      } catch (e) {
        firstError ??= e;
        return <Itinerary>[];
      }
    }));
    final stayIt = await stay;
    if (batches.every((b) => b.isEmpty) && stayIt == null && firstError != null) throw firstError!;
    return _finish([...batches.expand((b) => b), ?stayIt], to, toName, riding: trip);
  }

  /// Journeys from [from] to [to] ([toName] names the last walk).
  Future<List<RouteGroup>> search(LatLng from, LatLng to, {String toName = ''}) async {
    Object? firstError;
    final batches = await Future.wait(profiles.map((p) async {
      try {
        return await planner.plan(from, to, options: p.options);
      } catch (e) {
        firstError ??= e;
        return <Itinerary>[];
      }
    }));
    if (batches.every((b) => b.isEmpty) && firstError != null) throw firstError!;
    return _finish(batches.expand((b) => b).toList(), to, toName);
  }

  /// Rule 1 on the alternatives, then the walking rule, then rule 2 on the
  /// journeys as they will be shown (buses replaced by a walk are not
  /// judged), then grouping.
  Future<List<RouteGroup>> _finish(List<Itinerary> raw, LatLng to, String toName, {OnBoardTrip? riding}) async {
    final rides = [for (final it in raw) ...it.transitLegs];
    var all = [for (final it in raw) trimAlternatives(it, rides: rides)];
    final cache = walks, details = trips;
    if (cache != null) all = await applyWalkRules(all);
    if (cache != null && details != null) {
      all = await checkStayingOn(
        all,
        riding: riding,
        to: to,
        toName: toName,
        runOf: details.trip,
        walks: cache,
        policy: stayOn,
        maxWalk: policy.maxStayOnWalk,
        walkSpeed: walkingSpeedKmh / 3.6,
      );
    }
    return group(all);
  }

  /// Keeps only alternatives that board and get off near the planned ride's
  /// stops ([WalkPolicy.maxAlternativeStopDistanceMeters]) and that haven't
  /// left yet.
  ///
  /// Rule 1: right after a ride on line X, an alternative on X is pointless
  /// when [rides] (every ride of every journey found) include a direct X
  /// from that ride's boarding stop to this leg's destination: staying on
  /// gets you there, so getting off to wait for the next X never helps.
  /// Without such a ride (e.g. the first X ends here) it's a real option.
  Itinerary trimAlternatives(Itinerary it, {Iterable<Leg> rides = const []}) {
    final max = policy.maxAlternativeStopDistanceMeters;
    final now = _clock();
    var changed = false;
    String line(Leg l) => l.routeShortName ?? l.mode;
    bool near(LatLng a, LatLng b) => distanceMeters(a, b) <= max;
    Leg? previousRide(int i) {
      for (var j = i - 1; j >= 0; j--) {
        if (it.legs[j].transit) return it.legs[j];
      }
      return null;
    }

    final legs = [
      for (final (i, l) in it.legs.indexed)
        if (l.alternatives.isEmpty)
          l
        else
          () {
            final prev = previousRide(i);
            final stayOnWorks = prev != null &&
                rides.any((d) => line(d) == line(prev) && near(d.from, prev.from) && near(d.to, l.to));
            final keep = [
              for (final a in l.alternatives)
                if (a.reachableFrom(now) &&
                    !(stayOnWorks && a.line == line(prev)) &&
                    near(a.ride.from, l.from) &&
                    near(a.ride.to, l.to))
                  a,
            ];
            if (keep.length == l.alternatives.length) return l;
            changed = true;
            return l.withAlternatives(keep);
          }(),
    ];
    return changed ? it.withLegs(legs) : it;
  }

  /// Rule 1: replace rides by walking where it's pointless or slower to ride.
  ///
  /// For every ride whose span (ride + walks around it) is at most
  /// [WalkPolicy.maxWalkKm] long, the street walk over that span is fetched
  /// (cached, at most [WalkPolicy.maxWalkRequests] per search, earliest
  /// itineraries first). Arrivals are compared from when you could start
  /// walking (now for the first ride, else when the previous ride arrives),
  /// so waiting for the bus counts. Rides are only replaced when the rest of
  /// the trip still connects; the original stays in [Itinerary.base].
  Future<List<Itinerary>> applyWalkRules(List<Itinerary> all) async {
    final cache = walks;
    if (cache == null) return all;
    final now = _clock();
    final transit = all.where((it) => !it.walkOnly).toList()..sort(_byArrival);
    final tvs = [for (final it in transit) TripVariants(it, walks: cache, policy: policy, clock: _clock)];

    // Rides too short to show must be replaced: their walks come first.
    await cache.fetch([
      for (final tv in tvs)
        for (final s in tv.hiddenSlots)
          if (tv.walkIndex(s) != null) tv.slotSpan(s),
    ], max: policy.maxWalkRequests);
    await cache.fetch([
      for (final tv in tvs)
        for (var s = 0; s < tv.slotCount; s++)
          if (tv.walkIndex(s) != null) tv.slotSpan(s),
    ], max: policy.maxWalkRequests);
    for (final tv in tvs) {
      tv.restore(tv.choices); // recompose with the routes just fetched
    }

    for (final tv in tvs) {
      for (var s = 0; s < tv.slotCount; s++) {
        final wi = tv.walkIndex(s);
        if (wi == null || tv.isWalk(s, tv.choiceOf(s))) continue;
        final (from, to) = tv.slotSpan(s);
        final route = cache.lookup(from, to);
        if (route == null) continue; // unknown: keep the ride, never guess
        final start = s == 0 ? now : tv.spanStart(s);
        final walkArrival = start.add(route.duration);
        if (!policy.walkInsteadOfRide(
          rideDuration: tv.slotRide(s).duration,
          rideArrival: tv.spanEnd(s),
          walkArrival: walkArrival,
          walk: route.duration,
        )) {
          continue;
        }
        final before = tv.choices;
        if (!tv.choose(s, wi) || !tv.feasible) tv.restore(before);
      }
    }

    // Consecutive walked rides merge into one walk: fetch those routes too.
    await cache.fetch(tvs.expand((tv) => tv.missingWalks), max: policy.maxWalkRequests);
    final keep = <TripVariants>[];
    for (final tv in tvs) {
      tv.refresh();
      if (!tv.feasible || tv.missingWalks.isNotEmpty) tv.restore(tv.defaults);
      // A too-short ride that can't be walked (route unknown or too long) or
      // replaced by another ride: drop the whole itinerary.
      if (tv.hasHidden && (tv.impossible || !tv.feasible || tv.missingWalks.isNotEmpty)) continue;
      keep.add(tv);
    }
    return [
      for (final tv in keep) tv.current.walkSlots.isEmpty && !tv.hasHidden ? tv.base : tv.current,
      ...all.where((it) => it.walkOnly),
    ];
  }

  /// Dedupe identical trips, group by line sequence, rank and tag.
  ///
  /// [sectionOf] puts each journey in its list section (e.g. live or
  /// scheduled, by how sure its buses' times are): a row only holds
  /// journeys of one section, so every option you swipe to belongs where
  /// the row is.
  List<RouteGroup> group(Iterable<Itinerary> all, {String Function(Itinerary)? sectionOf}) {
    final now = _clock().subtract(const Duration(minutes: 1));
    final unique = <String, Itinerary>{};
    for (var it in all) {
      // Its first ride has left: gone (unless it starts on the vehicle
      // you're already on). Still to leave, but you can't be at its stop in
      // time: listed as a missed connection, its next bus a swipe away.
      if (it.start.isBefore(now) && !(it.legs.firstOrNull?.onBoard ?? false)) {
        if (!it.lateForFirstRide(_clock())) continue;
        it = it.withMissedConnection();
      }
      // Same lines on the same vehicles = same trip, whatever the walking
      // around it. Walking the whole way is one option, whenever you leave.
      final key = it.walkOnly
          ? 'walk'
          : '${it.signature}|${it.transitLegs.map((l) => l.tripId ?? l.start.toIso8601String()).join(',')}';
      // The same journey shown and under "show more": keep the shown one.
      final prev = unique[key];
      final prevHidden = prev?.hiddenBecause != null, hidden = it.hiddenBecause != null;
      if (prev == null || (prevHidden && !hidden) || (prevHidden == hidden && _better(it, prev))) unique[key] = it;
    }

    // Journeys under "show more" form their own groups.
    final groups = <String, List<Itinerary>>{};
    for (final it in unique.values) {
      final section = sectionOf?.call(it) ?? '';
      (groups['$section|${it.hiddenBecause == null ? '' : 'hidden:'}${it.signature}'] ??= []).add(it);
    }
    // Routes that differ only by which interchangeable line they take (60 ›
    // 19BUS and 60 › 3BUS, when the 3BUS is an alternative of the 19BUS) show
    // the same split pill: one route, its earliest departure first.
    final merged = <List<Itinerary>>[];
    for (final g in groups.values.map((v) => v..sort(_byArrival)).toList()..sort((a, b) => _byArrival(a.first, b.first))) {
      final same = g.first.walkOnly
          ? null
          : merged
              .where((m) =>
                  (m.first.hiddenBecause == null) == (g.first.hiddenBecause == null) &&
                  sectionOf?.call(m.first) == sectionOf?.call(g.first) &&
                  _interchangeable(m.first, g.first))
              .firstOrNull;
      if (same == null) {
        merged.add(g);
      } else {
        same
          ..addAll(g)
          ..sort(_byArrival);
      }
    }
    final result = [
      for (final m in merged) RouteGroup(m.first.signature, m.take(m.first.walkOnly ? 1 : maxPerGroup).toList()),
    ]..sort((a, b) => _byArrival(a.best, b.best));
    if (result.isEmpty) return result;

    // Tags describe the journeys listed normally that can be made.
    final shown = result.where((g) => g.hiddenBecause == null && !g.best.missedConnection).toList();
    shown.firstOrNull?.tags.add(RouteTag.fastest);
    final transit = shown.where((g) => !g.isWalk).toList();
    if (transit.isNotEmpty) {
      // Every route that has the fewest changes (or the least walking) says
      // so, when that's better than the fastest route: otherwise one route
      // with one bus would go untagged while another with two had the tag.
      final fastestTransit = transit.first;
      void tagMin(RouteTag tag, int Function(Itinerary) f) {
        final least = transit.map((g) => f(g.best)).reduce((a, b) => a < b ? a : b);
        if (least >= f(fastestTransit.best)) return;
        for (final g in transit) {
          if (f(g.best) == least) g.tags.add(tag);
        }
      }

      tagMin(RouteTag.fewestChanges, (it) => it.transfers);
      tagMin(RouteTag.leastWalking, (it) => it.walkMinutes);
    }

    // Order by arrival + the cost of changes (tags above stay on the
    // truly fastest / fewest-changes routes).
    result.sort((a, b) {
      final c = rank.score(a.best).compareTo(rank.score(b.best));
      return c != 0 ? c : _byArrival(a.best, b.best);
    });

    // Rule 2: walking the whole way, suggested first when about as fast.
    final walk = result.where((g) => g.isWalk).firstOrNull;
    if (walk != null &&
        policy.suggestWalking(
          walk: walk.best.duration,
          walkArrival: walk.best.end,
          bestTransitArrival: transit.firstOrNull?.best.end,
        )) {
      walk.tags.add(RouteTag.onFoot);
      result
        ..remove(walk)
        ..insert(0, walk);
    }

    // On board: staying on first (changes not worth it are under "show
    // more", see checkStayingOn).
    final stay = result.where((g) => g.hiddenBecause == null && staysOnBoard(g.best)).firstOrNull;
    if (stay != null) {
      stay.tags.add(RouteTag.stayOnBoard);
      result
        ..remove(stay)
        ..insert(0, stay);
    }
    return result;
  }

  /// Same rides leg by leg, up to interchangeable lines: boarding and getting
  /// off near the same stops, with a line in common among each leg's line
  /// and its alternatives.
  bool _interchangeable(Itinerary a, Itinerary b) {
    final ra = a.transitLegs.toList(), rb = b.transitLegs.toList();
    if (ra.isEmpty || ra.length != rb.length) return false;
    final max = policy.maxAlternativeStopDistanceMeters;
    Set<String> lines(Leg l) => {l.routeShortName ?? l.mode, for (final x in l.alternatives) x.line};
    for (var i = 0; i < ra.length; i++) {
      if (distanceMeters(ra[i].from, rb[i].from) > max || distanceMeters(ra[i].to, rb[i].to) > max) return false;
      if (lines(ra[i]).intersection(lines(rb[i])).isEmpty) return false;
    }
    return true;
  }

  static int _byArrival(Itinerary a, Itinerary b) {
    final c = a.end.compareTo(b.end);
    return c != 0 ? c : b.start.compareTo(a.start); // same arrival: leave later
  }

  /// Between two versions of the same trip prefer less walking, then later departure.
  static bool _better(Itinerary a, Itinerary b) =>
      a.walkMinutes != b.walkMinutes ? a.walkMinutes < b.walkMinutes : a.start.isAfter(b.start);
}
