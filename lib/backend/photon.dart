import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';

import 'backend.dart';

/// Photon (komoot's OpenStreetMap search, photon.komoot.io): addresses and
/// places, typo-tolerant, made for search-as-you-type. Used when Tramite's
/// place search can't answer. Stops are left out: MOTIS has them with their
/// stop ids.
class PhotonClient {
  PhotonClient({this.baseUrl = 'https://photon.komoot.io', http.Client? client}) : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  /// Photon's languages besides local names ("default").
  static const _languages = {'en', 'de', 'fr'};

  Future<List<Place>> search(String query, {LatLng? near, String? lang}) async {
    final uri = Uri.parse('$baseUrl/api/').replace(
      queryParameters: {
        'q': query,
        'limit': '15',
        if (lang != null && _languages.contains(lang)) 'lang': lang,
        if (near != null) ...{'lat': '${near.latitude}', 'lon': '${near.longitude}'},
      },
    );
    final res = await _client.get(uri, headers: kHeaders).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception('Photon ${res.statusCode}: ${res.body}');
    final d = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return [for (final f in (d['features'] as List).cast<Map<String, dynamic>>()) ?_place(f)];
  }

  static Place? _place(Map<String, dynamic> f) {
    final p = f['properties'] as Map<String, dynamic>;
    final key = p['osm_key'] as String?, value = p['osm_value'] as String?;
    if (_isStop(key, value)) return null;
    final c = (f['geometry'] as Map<String, dynamic>)['coordinates'] as List;
    final street = [p['street'], p['housenumber']].whereType<String>().join(' ');
    final name = p['name'] as String?;
    // A house number, a street, a building; Photon's own "type" is "house"
    // for named places too.
    final isAddress = name == null || key == 'highway' || key == 'building' || (key == 'place' && value == 'house');
    final title = name ?? (street.isNotEmpty ? street : null);
    if (title == null) return null;
    final city = (p['city'] ?? p['county'] ?? p['state']) as String?;
    return Place(
      name: title,
      subtitle: {
        if (name != null && street.isNotEmpty && street != name) street,
        ?(p['locality'] ?? p['district']) as String?,
        ?city,
      }.join(', ').emptyAsNull,
      position: LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
      kind: isAddress ? PlaceKind.address : PlaceKind.place,
    );
  }

  /// Stops, stations and the railway's bits (entrances, platforms, works,
  /// lifts): the timetable's own stops, from MOTIS, stand for them. Of
  /// highway features only roads are kept (no bus stops, crossings, lifts).
  static bool _isStop(String? key, String? value) =>
      key == 'public_transport' ||
      key == 'railway' ||
      (key == 'amenity' && value == 'bus_station') ||
      (key == 'highway' && !_roads.contains(value?.replaceFirst('_link', '')));

  static const _roads = {
    'motorway', 'trunk', 'primary', 'secondary', 'tertiary', 'unclassified', 'residential', 'living_street',
    'pedestrian', 'service', 'road', 'track', 'footway', 'path', 'cycleway', 'steps',
  };
}

extension on String {
  String? get emptyAsNull => isEmpty ? null : this;
}
