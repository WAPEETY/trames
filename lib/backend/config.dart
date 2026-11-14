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
final MotisClient _motis = MotisClient(baseUrl: kMotisUrl, walkingSpeedKmh: kWalkingSpeedKmh);

/// Transitous, the public MOTIS server the app uses unless set otherwise.
const kMotisUrl = 'https://api.transitous.org';

/// Points the app at other servers (settings). Live data is followed again
/// on the new Tramite stream.
void useServers({required String motis, required String tramiteUrl}) {
  _motis.switchTo(motis);
  if (tramite.baseUrl != tramiteUrl) {
    tramite.switchTo(tramiteUrl);
    live.reconnect();
  }
}

/// Checks a server before switching to it.
Future<bool> checkMotis(String url) => _motis.checkServer(url);
Future<bool> checkTramite(String url) => tramite.checkServer(url);

/// Tramite, our realtime service, for the whole app: it says itself which
/// stops, trips and lines it covers. The settings page can point it elsewhere ([useServers]).
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
