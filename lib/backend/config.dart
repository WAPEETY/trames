import 'package:flutter/foundation.dart' show kIsWeb;

import 'backend.dart';
import 'gtfs_rt_vehicles.dart';
import 'motis.dart';
import 'opentransit.dart';
import 'walk_rules.dart';

/// Transitous (public MOTIS): routing, search, departures, trips, walking.
/// One instance for the whole app, so its caches survive city switches.
///
/// Self-hosting later:
///  * own MOTIS server  -> `MotisClient(baseUrl: 'https://motis.example.org')`
///  * own OTP server    -> write `OtpClient implements TripPlanner, StopBoards`
///  * own geocoder      -> any `PlaceSearch` (e.g. a Photon/Pelias client)
final MotisClient _motis = MotisClient(walkingSpeedKmh: kWalkingSpeedKmh);

/// Backend for [city]: Transitous everywhere, plus the city's extras (its
/// feed id, its live GPS feed). With no city: Transitous only.
TransitBackend createBackend({CityConfig? city}) {
  _motis.vehicleFeedId = city?.motisFeedId;
  final gps = city?.vehicleFeedUrl;
  return TransitBackend(
    name: city == null ? 'Transitous' : 'Transitous + ${city.name}',
    city: city,
    planner: _motis,
    places: _motis,
    stops: _motis,
    // Web builds can't read most operator feeds directly (no CORS headers):
    // pass a proxy with --dart-define=CORS_PROXY=http://localhost:8787/?url=
    vehicles: gps == null ? null : GtfsRtVehicleFeed(gps, proxy: kIsWeb ? const String.fromEnvironment('CORS_PROXY') : ''),
    paths: _motis,
    trips: _motis,
    walks: _motis,
    returns: _motis,
  );
}

/// Rome (used by the live tests).
TransitBackend transitousRome() => createBackend(city: kRomeConfig);

/// opentransit.tech for everything (OpenTripPlanner 2 underneath), Rome only.
TransitBackend openTransitRome() {
  final ot = OpenTransitClient();
  return TransitBackend(name: 'opentransit', city: kRomeConfig, planner: ot, places: ot, stops: ot, vehicles: ot);
}
