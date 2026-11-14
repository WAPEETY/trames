import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';

import 'backend.dart';

/// opentransit.tech API (OpenTripPlanner 2 behind a FastAPI layer).
/// Kept as an alternate backend; see config.dart.
class OpenTransitClient implements TripPlanner, PlaceSearch, StopBoards {
  OpenTransitClient({this.baseUrl = 'https://api.opentransit.tech/v1/cities/roma', this.idPrefix = 'roma:', http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;

  /// opentransit namespaces ids per city ("roma:0#4103-14").
  final String idPrefix;
  final http.Client _client;

  Future<Map<String, dynamic>> _get(String path, Map<String, String> query) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final res = await _client.get(uri, headers: kHeaders).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw Exception('opentransit ${res.statusCode}: ${res.body}');
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  String? _raw(String? id) => id == null ? null : (id.startsWith(idPrefix) ? id.substring(idPrefix.length) : id);
  static DateTime _time(String s) => DateTime.parse(s).toLocal();
  static LatLng _pos(Map<String, dynamic> j) => LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble());

  @override
  Future<List<Itinerary>> plan(LatLng from, LatLng to, {PlanOptions options = const PlanOptions()}) async {
    final d = await _get('/plan', {
      'fromLat': '${from.latitude}',
      'fromLon': '${from.longitude}',
      'toLat': '${to.latitude}',
      'toLon': '${to.longitude}',
      'numItineraries': '8',
    });
    return [
      for (final j in d['itineraries'] as List)
        Itinerary(
          start: _time(j['startTime']),
          end: _time(j['endTime']),
          transfers: j['transfers'] as int? ?? 0,
          legs: [for (final l in j['legs'] as List) _leg(l)],
        ),
    ];
  }

  Leg _leg(Map<String, dynamic> j) {
    final from = j['from'] as Map<String, dynamic>;
    final to = j['to'] as Map<String, dynamic>;
    final geom = j['geometry'];
    final encoded = geom is Map ? geom['encoded'] as String? : null;
    return Leg(
      mode: j['mode'] as String,
      transit: j['transit'] as bool? ?? false,
      start: _time(j['startTime']),
      end: _time(j['endTime']),
      fromName: from['name'] as String? ?? '',
      toName: to['name'] as String? ?? '',
      from: _pos(from),
      to: _pos(to),
      points: encoded != null ? decodePolyline(encoded) : [_pos(from), _pos(to)],
      distanceMeters: (j['distanceMeters'] as num?)?.toDouble() ?? 0,
      routeShortName: (j['route'] as Map?)?['shortName'] as String?,
      headsign: j['headsign'] as String?,
      tripId: _raw(j['tripId'] as String?),
      realtime: j['realtime'] as bool? ?? false,
      delaySeconds: j['delaySeconds'] as int?,
      intermediateStops: (j['intermediateStops'] as List?)?.length ?? 0,
    );
  }

  @override
  Future<List<Place>> search(String query, {LatLng? near}) async {
    final d = await _get('/geocode', {'q': query});
    return [
      for (final r in d['results'] as List)
        Place(name: r['name'] as String, subtitle: r['label'] as String?, position: _pos(r)),
    ];
  }

  @override
  Future<List<Stop>> nearbyStops(LatLng p) async {
    final d = await _get('/stops/nearby', {'lat': '${p.latitude}', 'lon': '${p.longitude}'});
    return [
      for (final j in d['stops'] as List)
        Stop(
          id: j['id'] as String,
          code: j['code'] as String?,
          name: j['name'] as String? ?? '',
          position: _pos(j),
          distanceMeters: (j['distanceMeters'] as num?)?.round() ?? 0,
        ),
    ];
  }

  /// No bounding-box endpoint: nearby stops around [from], kept if inside.
  @override
  Future<List<Stop>> stopsInArea(LatLngBounds area, {required LatLng from}) async {
    bool inside(LatLng p) =>
        p.latitude >= area.southwest.latitude &&
        p.latitude <= area.northeast.latitude &&
        p.longitude >= area.southwest.longitude &&
        p.longitude <= area.northeast.longitude;
    return (await nearbyStops(from)).where((s) => inside(s.position)).toList();
  }

  @override
  Future<List<BoardRow>> board(Stop stop) async {
    final d = await _get('/stops/${Uri.encodeComponent(stop.id)}/board', {});
    final items = <({String line, String mode, String headsign, Departure departure})>[];
    for (final r in d['rows'] as List) {
      final route = r['route'] as Map<String, dynamic>;
      for (final n in r['next'] as List) {
        items.add((
          line: route['shortName'] as String? ?? '?',
          mode: route['mode'] as String? ?? 'BUS',
          headsign: r['headsign'] as String? ?? '',
          departure: Departure(
            time: _time(n['time'] as String),
            realtime: n['realtime'] as bool? ?? false,
            delaySeconds: n['delaySeconds'] as int?,
            tripId: _raw(n['tripId'] as String?),
          ),
        ));
      }
    }
    return groupDepartures(stop, items);
  }

}
