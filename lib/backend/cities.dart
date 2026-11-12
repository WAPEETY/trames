import 'package:maplibre_gl/maplibre_gl.dart';

import 'models.dart';

/// What the app knows about a city beyond Transitous: its feed id there and
/// an optional live GPS feed. Anywhere without a config the app runs on
/// Transitous alone (routes, departures, live times where Transitous has
/// them), without live bus positions or line search.
///
/// To add a city: add an entry to [kCities].
class CityConfig {
  CityConfig({
    required this.id,
    required this.name,
    required this.area,
    required this.fallbackCenter,
    required this.motisFeedId,
    this.vehicleFeedUrl,
  });

  final String id;
  final String name;

  /// Where this config applies (map centre / your position inside it).
  final LatLngBounds area;

  /// Where to start when location is unavailable.
  final Place fallbackCenter;

  /// The city's feed id in Transitous (prefix of its stop and trip ids), for
  /// stop-number search and to link live vehicles to Transitous trips.
  final String motisFeedId;

  /// GTFS-realtime VehiclePositions feed (live GPS), if the city has one.
  final String? vehicleFeedUrl;

  bool contains(LatLng p) =>
      p.latitude >= area.southwest.latitude &&
      p.latitude <= area.northeast.latitude &&
      p.longitude >= area.southwest.longitude &&
      p.longitude <= area.northeast.longitude;
}

final kRomeConfig = CityConfig(
  id: 'rome',
  name: 'Roma',
  area: LatLngBounds(southwest: const LatLng(41.65, 12.20), northeast: const LatLng(42.10, 12.85)),
  fallbackCenter: const Place(name: 'Roma Termini', position: LatLng(41.9010, 12.5013)),
  motisFeedId: 'it-Lazio-Rome',
  // Roma Mobilità open data (no key). Its route_id is the public line name.
  vehicleFeedUrl: 'https://romamobilita.it/wp-content/uploads/shared/rome_rtgtfs_vehicle_positions_feed.pb',
);

/// Supported cities. The first one is also where the app opens without
/// location.
final kCities = <CityConfig>[kRomeConfig];

/// The configured city containing [p], or null (Transitous only).
CityConfig? cityAt(LatLng p) {
  for (final c in kCities) {
    if (c.contains(p)) return c;
  }
  return null;
}
