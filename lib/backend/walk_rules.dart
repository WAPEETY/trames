/// Walking pace used for every walking time (planner requests and the
/// placeholder shown while a walking route loads), km/h. Set from the
/// settings with useWalkingSpeed (config.dart).
double walkingSpeedKmh = 5.0;

/// When walking should replace a ride, or the whole trip.
class WalkPolicy {
  const WalkPolicy({
    this.shortRide = const Duration(minutes: 4),
    this.shortRideSlack = const Duration(minutes: 1),
    this.maxWalkKm = 3,
    this.suggestWalkMax = const Duration(minutes: 25),
    this.suggestWalkSlack = const Duration(minutes: 3),
    this.maxWalkRequests = 6,
    this.hideRidesUpTo = const Duration(minutes: 1),
    this.maxAlternativeStopDistanceMeters = 300,
    this.maxRideWalk,
    this.maxStayOnWalk = const Duration(minutes: 10),
    this.earlierRideWait = const Duration(minutes: 30),
  });

  /// An earlier bus that gets you there no sooner is still taken when you
  /// leave at most this much before: that much more waiting on the way,
  /// rather than leaving later to make the connection exactly. (One that
  /// gets you there sooner is always taken; see applyLiveTimes.)
  final Duration earlierRideWait;

  /// Staying on a bus "takes you there" when the walk from its stop nearest
  /// the destination is at most this long (see checkStayingOn).
  final Duration maxStayOnWalk;

  /// Walking replaces a ride only when the walk takes at most this long
  /// (null: any length up to [maxWalkKm]). Longer walks stay available as a
  /// swipe option in the trip view, not chosen by default.
  final Duration? maxRideWalk;

  /// A planner "alternative" for a ride only counts as one (split pill,
  /// swipe) when it boards and gets off within this distance of the planned
  /// ride's stops. Farther ones are different routes, listed on their own.
  final double maxAlternativeStopDistanceMeters;

  /// Rides this short are never offered: walking or another ride replaces
  /// them, or the itinerary is dropped.
  final Duration hideRidesUpTo;

  /// A ride this short is pointless when walking arrives at most
  /// [shortRideSlack] later.
  final Duration shortRide;
  final Duration shortRideSlack;

  /// Walking is only considered for stretches up to this straight-line
  /// distance.
  final double maxWalkKm;

  /// Walking the whole way is suggested first when it takes at most
  /// [suggestWalkMax] and arrives at most [suggestWalkSlack] after the best
  /// transit option.
  final Duration suggestWalkMax;
  final Duration suggestWalkSlack;

  /// Walking routes fetched per search (parallel, cached).
  final int maxWalkRequests;

  /// Rule 1: should a ride of [rideDuration] arriving at [rideArrival] be
  /// walked instead, given walking would arrive at [walkArrival]? Arrivals are
  /// counted from when you reach the stop, so the wait is included.
  bool walkInsteadOfRide({
    required Duration rideDuration,
    required DateTime rideArrival,
    required DateTime walkArrival,
    Duration? walk,
  }) {
    final cap = maxRideWalk;
    if (cap != null && walk != null && walk > cap) return false;
    if (!walkArrival.isAfter(rideArrival)) {
      return true; // walking is simply faster
    }
    return rideDuration <= shortRide &&
        !walkArrival.isAfter(rideArrival.add(shortRideSlack));
  }

  /// Rule 2: suggest walking the whole way?
  bool suggestWalking({
    required Duration walk,
    required DateTime walkArrival,
    required DateTime? bestTransitArrival,
  }) {
    if (walk > suggestWalkMax) return false;
    if (bestTransitArrival == null) return true;
    return !walkArrival.isAfter(bestTransitArrival.add(suggestWalkSlack));
  }
}

const kWalkPolicy = WalkPolicy();
