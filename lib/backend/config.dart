import 'backend.dart';
import 'live_connection.dart';
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

/// Tramite, our realtime service, for the whole app: it says itself which
/// stops, trips and lines it covers. A future settings page changes [kTramiteUrl].
final TramiteClient tramite = TramiteClient(baseUrl: kTramiteUrl);

/// The app's one subscription stream to Tramite.
final LiveConnection live = LiveConnection(tramite);

/// Backend for [city]: Transitous (routes, search, stops, timetables, trips,
/// walking). With no city, the same without a home feed for stop numbers.
TransitBackend createBackend({CityConfig? city}) {
  _motis.homeFeedId = city?.motisFeedId;
  return TransitBackend(
    name: city == null ? 'Transitous' : 'Transitous ${city.name}',
    city: city,
    planner: _motis,
    places: _motis,
    stops: _motis,
    paths: _motis,
    trips: _motis,
    walks: _motis,
  );
}

/// Rome (used by the live tests).
TransitBackend transitousRome() => createBackend(city: kRomeConfig);

/// opentransit.tech for everything (OpenTripPlanner 2 underneath), Rome only.
TransitBackend openTransitRome() {
  final ot = OpenTransitClient();
  return TransitBackend(name: 'opentransit', city: kRomeConfig, planner: ot, places: ot, stops: ot);
}
