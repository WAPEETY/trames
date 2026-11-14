import 'package:maplibre_gl/maplibre_gl.dart';

import 'models.dart';

/// What the app knows about a city beyond Transitous: where to start without
/// location, and its feed id there (stop-number search). Realtime extras
/// don't depend on this list: Tramite says what it covers (see
/// TramiteClient.covers).
///
/// To add a city: add an entry to [kCities].
class CityConfig {
  CityConfig({
    required this.id,
    required this.name,
    required this.area,
    required this.fallbackCenter,
    required this.motisFeedId,
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
);

/// Our realtime service (https://git.marcorealacci.me/marcorealacci/tramite).
/// Override with --dart-define=TRAMITE_URL=http://localhost:8080
const kTramiteUrl = String.fromEnvironment('TRAMITE_URL', defaultValue: 'https://tramite.realac.ci');

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
