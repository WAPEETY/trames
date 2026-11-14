import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';

import 'backend.dart';

/// Tramite, our realtime service: fresh operator data, buses waiting at the
/// terminus, buses that vanish near it, inferred departures. Its ids are
/// Transitous's, each with its source's prefix (`it-Lazio-Rome_71527`), so
/// the app asks Tramite about exactly the stops, trips and lines it covers
/// and Transitous about the rest (see [covers]).
///
/// Live data comes through one subscription stream ([LiveConnection]); this
/// class holds the plain requests and the JSON parsing.
class TramiteClient {
  TramiteClient({required this.baseUrl, http.Client? client}) : _client = client ?? http.Client();

  /// e.g. https://tramite.realac.ci
  String baseUrl;

  /// Talk to another Tramite server from now on (settings): what it covers
  /// is asked again.
  void switchTo(String url) {
    if (url == baseUrl) return;
    baseUrl = url;
    _prefixes = const [];
    _coverageAt = null;
    loadCoverage();
  }

  /// Whether [url] answers like a Tramite server.
  Future<bool> checkServer(String url) async {
    try {
      final res = await _client.get(Uri.parse('$url/v1/sources'), headers: kHeaders).timeout(const Duration(seconds: 10));
      return res.statusCode == 200 && res.body.trimLeft().startsWith('[');
    } catch (_) {
      return false;
    }
  }
  final http.Client _client;

  Uri uri(String path, [Map<String, dynamic>? query]) => Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Future<dynamic> _get(String path) async {
    final res = await _client.get(uri(path), headers: kHeaders).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw TramiteException(res.statusCode, utf8.decode(res.bodyBytes));
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  /// Adds and removes topics of the open stream [streamId].
  Future<void> updateTopics(String streamId, {Iterable<String> add = const [], Iterable<String> remove = const []}) async {
    final res = await _client
        .post(uri('/v1/stream/$streamId/topics'),
            headers: {...kHeaders, 'Content-Type': 'application/json'},
            body: jsonEncode({'add': add.toList(), 'remove': remove.toList()}))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 204) throw TramiteException(res.statusCode, utf8.decode(res.bodyBytes));
  }

  // ---- coverage ----

  List<String> _prefixes = const [];
  DateTime? _coverageAt;
  Future<void>? _loading;

  /// Id prefixes of the sources Tramite serves, e.g. `it-Lazio-Rome`.
  List<String> get prefixes => _prefixes;

  /// Asks Tramite what it covers (once, again after a failure). Until it
  /// answers, nothing counts as covered and everything goes to Transitous.
  Future<void> loadCoverage() {
    final at = _coverageAt;
    if (_prefixes.isNotEmpty || (at != null && DateTime.now().difference(at) < const Duration(seconds: 30))) {
      return Future.value();
    }
    return _loading ??= () async {
      try {
        final list = await _get('/v1/sources') as List;
        _prefixes = [for (final s in list.cast<Map<String, dynamic>>()) ?s['idPrefix'] as String?];
      } catch (_) {
        // unreachable: Transitous only, retried later
      } finally {
        _coverageAt = DateTime.now();
        _loading = null;
      }
    }();
  }

  /// The source prefix of a stop, line or trip id when Tramite covers it.
  /// Trip ids are `<date>_<HH:MM>_<prefix>_<trip>`.
  String? prefixOf(String? id) {
    if (id == null) return null;
    final trip = RegExp(r'^\d{8}_\d+:\d{2}_(.*)$').firstMatch(id);
    final rest = trip?.group(1) ?? id;
    String? best;
    for (final p in _prefixes) {
      if (rest.startsWith('${p}_') && (best == null || p.length > best.length)) best = p;
    }
    return best;
  }

  bool covers(String? id) => prefixOf(id) != null;

  // ---- topics ----

  /// A stop's departures; with [tripId], that trip's row at the stop only.
  /// [lineId] (the trip's line) lets Tramite match a trip id of another
  /// timetable version (Transitous may lag a feed that renumbers its trips).
  static String departuresTopic(String stopId, {String? tripId, String? lineId}) => tripId == null
      ? 'departures=$stopId'
      : 'departures=$stopId,trip=$tripId${lineId == null ? '' : ',line=$lineId'}';
  static String lineTopic(String lineId) => 'line=$lineId';
  static String bboxTopic(LatLngBounds b) => 'bbox=${[
        b.southwest.latitude,
        b.southwest.longitude,
        b.northeast.latitude,
        b.northeast.longitude,
      ].map((x) => x.toStringAsFixed(5)).join(',')}';

  /// A line as Tramite names it: its operator's prefix and the number
  /// passengers see ("it-Lazio-Rome_85").
  static String lineId(String prefix, String number) => '${prefix}_$number';

  // ---- one-shot requests ----

  /// Live buses of a line right now (line search, the line view's directions).
  Future<List<({Vehicle vehicle, String? color})>> lineVehicles(String lineId) async {
    final list = await _get('/v1/lines/${Uri.encodeComponent(lineId)}/vehicles') as List;
    return [for (final j in list.cast<Map<String, dynamic>>()) parseVehicle(j)];
  }

  // ---- parsing ----

  static DateTime _time(String s) => DateTime.parse(s).toLocal();

  /// A Tramite vehicle as the app's [Vehicle], with its line colour.
  static ({Vehicle vehicle, String? color}) parseVehicle(Map<String, dynamic> j) {
    final color = j['routeColor'] as String?;
    return (
      vehicle: Vehicle(
        id: j['id'] as String,
        label: j['id'] as String,
        tripId: j['gtfsTripId'] as String?,
        backendTripId: j['tripId'] as String?,
        routeShortName: j['routeShortName'] as String?,
        position: LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()),
        timestamp: _time(j['timestamp'] as String),
        bearing: (j['bearing'] as num?)?.toDouble(),
        directionId: j['directionId'] as int?,
        stopSequence: j['currentStopSequence'] as int?,
        stopId: j['stopId'] as String?,
      ),
      color: color == null || color.isEmpty ? null : '#$color',
    );
  }

  static List<({Vehicle vehicle, String? color})> parseVehicles(Object? data) =>
      [for (final j in (data as List? ?? const []).cast<Map<String, dynamic>>()) parseVehicle(j)];

  /// A departures topic or endpoint's data as board rows for [stop].
  static List<BoardRow> parseBoard(Object? data, Stop stop) =>
      groupDepartures(stop, [for (final r in parseRows(data)) if (!r.cancelled) r.item]);

  /// Each stop time of a departures answer: as a board item, plus what a
  /// followed ride needs (where its bus is).
  static List<TramiteRow> parseRows(Object? data) => [
        for (final s in ((data as Map<String, dynamic>?)?['stopTimes'] as List? ?? const []).cast<Map<String, dynamic>>())
          _row(s),
      ];

  static TramiteRow _row(Map<String, dynamic> s) {
    final time = _time(s['departure'] as String);
    final sched = _time(s['scheduledDeparture'] as String);
    final line = s['routeShortName'] as String? ?? '?';
    final from = s['tripFrom'] as Map<String, dynamic>?;
    final v = s['vehicle'] as Map<String, dynamic>?;
    final departure = Departure(
      time: time,
      realtime: s['realTime'] as bool? ?? false,
      delaySeconds: time.difference(sched).inSeconds,
      tripId: s['gtfsTripId'] as String?,
      backendTripId: s['tripId'] as String?,
      stopId: s['stopId'] as String?,
      origin: from == null
          ? null
          : TripOrigin(
              stopId: from['stopId'] as String,
              position: LatLng((from['lat'] as num).toDouble(), (from['lon'] as num).toDouble())),
      certainty: certaintyOf(s, time.difference(sched)),
    );
    Vehicle? bus;
    if (v != null && v['lat'] != null && v['timestamp'] != null) {
      bus = Vehicle(
        id: v['id'] as String,
        label: v['id'] as String,
        tripId: s['gtfsTripId'] as String?,
        backendTripId: s['tripId'] as String?,
        routeShortName: line,
        position: LatLng((v['lat'] as num).toDouble(), (v['lon'] as num).toDouble()),
        timestamp: _time(v['timestamp'] as String),
        bearing: (v['bearing'] as num?)?.toDouble(),
        directionId: s['directionId'] as int?,
        stopSequence: v['currentStopSequence'] as int?,
      );
    }
    return TramiteRow(
      item: (line: line, mode: _mode(s['routeType'] as int?), headsign: s['headsign'] as String? ?? '', departure: departure),
      scheduled: sched,
      inferred: s['departureTimestampReason'] == 'INFERRED',
      cancelled: s['cancelled'] == true,
      bus: bus,
    );
  }

  /// How sure a Tramite stop time is: inferred (on time or late), live with
  /// its bus not yet started (or no bus seen) or on its way, timetable.
  static Certainty certaintyOf(Map<String, dynamic> s, Duration delay) {
    if (s['departureTimestampReason'] == 'INFERRED') {
      return delay > Duration.zero ? Certainty.estimated : Certainty.returning;
    }
    if (s['realTime'] != true) return Certainty.scheduled;
    final v = s['vehicle'] as Map<String, dynamic>?;
    return v?['started'] == true ? Certainty.moving : Certainty.waiting;
  }

  /// GTFS route_type as MOTIS mode names (what the app has icons for).
  static String _mode(int? type) => switch (type) {
        0 || 900 => 'TRAM',
        1 || 401 => 'SUBWAY',
        2 || 100 || 106 => 'RAIL',
        4 || 1200 => 'FERRY',
        _ => 'BUS',
      };
}

/// One stop time from Tramite.
class TramiteRow {
  TramiteRow({required this.item, required this.scheduled, required this.inferred, required this.cancelled, this.bus});
  final ({String line, String mode, String headsign, Departure departure}) item;
  final DateTime scheduled;

  /// No forecast, but a known bus should run it ([Departure.time] is when).
  final bool inferred;
  final bool cancelled;

  /// The bus on this trip, with its position (live buses only).
  final Vehicle? bus;

  Departure get departure => item.departure;
}

class TramiteException implements Exception {
  TramiteException(this.status, this.body);
  final int status;
  final String body;
  @override
  String toString() => 'Tramite $status: $body';
}
