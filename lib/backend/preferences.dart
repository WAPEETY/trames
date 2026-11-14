import 'on_board.dart';
import 'route_search.dart';
import 'walk_rules.dart';

/// How much you like walking (settings): when walking replaces a ride, and
/// when walking the whole way is suggested.
enum WalkLiking {
  /// Walk instead of a ride only for walks up to 5 min.
  notAtAll(
      maxRideWalk: Duration(minutes: 5),
      suggestWalkMax: Duration(minutes: 8),
      maxStayOnWalk: Duration(minutes: 5),
      shortRideSlack: Duration.zero),

  /// Up to 12 min.
  aBit(
      maxRideWalk: Duration(minutes: 12),
      suggestWalkMax: Duration(minutes: 15),
      maxStayOnWalk: Duration(minutes: 12),
      shortRideSlack: Duration(minutes: 1)),

  /// Any walk that isn't slower (up to [WalkPolicy.maxWalkKm]).
  aLot(
      maxRideWalk: null,
      suggestWalkMax: Duration(minutes: 30),
      maxStayOnWalk: Duration(minutes: 20),
      shortRideSlack: Duration(minutes: 3));

  const WalkLiking({
    required this.maxRideWalk,
    required this.suggestWalkMax,
    required this.maxStayOnWalk,
    required this.shortRideSlack,
  });

  /// A bus ride of 4 min or less is walked when walking arrives at most
  /// this much later.
  final Duration shortRideSlack;
  final Duration? maxRideWalk;
  final Duration suggestWalkMax;

  /// Staying on a bus and walking at most this long "takes you there".
  final Duration maxStayOnWalk;

  WalkPolicy get policy =>
      WalkPolicy(
        maxRideWalk: maxRideWalk,
        suggestWalkMax: suggestWalkMax,
        maxStayOnWalk: maxStayOnWalk,
        shortRideSlack: shortRideSlack,
      );
}

/// How fast you walk (settings): a fixed pace, or [auto] learned from GPS
/// while you walk with the app open (see WalkCalibrator).
enum WalkSpeed {
  auto(null),
  slow(4.0),
  normal(5.0),
  fast(6.0);

  const WalkSpeed(this.kmh);

  /// The fixed pace, km/h; null for [auto].
  final double? kmh;
}

/// What to prefer between speed and fewer changes (settings). A route with
/// one change fewer is worth arriving max([changeFloor], [changeShare] ×
/// trip) later; the same bar decides when getting off the bus you're on to
/// change is worth it.
enum RoutePreference {
  fastest(changeFloor: Duration(minutes: 5), changeShare: 0.15),
  balanced(changeFloor: Duration(minutes: 5), changeShare: 0.25),
  fewerChanges(changeFloor: Duration(minutes: 10), changeShare: 0.30);

  const RoutePreference({required this.changeFloor, required this.changeShare});
  final Duration changeFloor;
  final double changeShare;

  RankPolicy get rank => RankPolicy(changeFloor: changeFloor, changeShare: changeShare, changeCap: null);
  StayOnPolicy get stayOn => StayOnPolicy(floor: changeFloor, share: changeShare);
}
