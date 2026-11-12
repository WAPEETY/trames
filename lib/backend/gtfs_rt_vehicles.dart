import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart' as rt;
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';

import 'backend.dart';

/// Live GPS positions straight from an operator's GTFS-realtime
/// VehiclePositions feed (protobuf). Independent of the trip planner, so it
/// works with Transitous, opentransit or a self-hosted router alike.
class GtfsRtVehicleFeed implements VehicleFeed {
  GtfsRtVehicleFeed(this.url, {this.proxy = '', http.Client? client}) : _client = client ?? http.Client();

  // Feed URLs live in the city configs (cities.dart). Operator servers often
  // send no CORS headers, so web builds go through a proxy (see
  // tools/cors_proxy.py and the CORS_PROXY dart-define in config.dart).

  final String url;

  /// Prefix prepended to [url], e.g. `http://localhost:8787/?url=` (empty = direct).
  final String proxy;
  final http.Client _client;

  static DateTime _epoch(int seconds) => DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

  @override
  Future<VehicleSnapshot> vehicles() async {
    final target = proxy.isEmpty ? url : '$proxy${Uri.encodeQueryComponent(url)}';
    final res = await _client.get(Uri.parse(target), headers: kHeaders).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw Exception('GTFS-RT ${res.statusCode}');
    final feed = rt.FeedMessage.fromBuffer(res.bodyBytes);
    final out = <Vehicle>[];
    for (final e in feed.entity) {
      if (!e.hasVehicle() || !e.vehicle.hasPosition()) continue;
      final v = e.vehicle;
      out.add(Vehicle(
        id: v.vehicle.id.isNotEmpty ? v.vehicle.id : e.id,
        label: v.vehicle.label,
        tripId: v.trip.hasTripId() ? v.trip.tripId : null,
        // Rome's route_id is the public line name (e.g. "n66", "451").
        routeShortName: v.trip.hasRouteId() ? v.trip.routeId : null,
        position: LatLng(v.position.latitude, v.position.longitude),
        timestamp: _epoch(v.timestamp.toInt()),
        bearing: v.position.hasBearing() ? v.position.bearing : null,
        startDate: v.trip.hasStartDate() ? v.trip.startDate : null,
        startTime: v.trip.hasStartTime() ? v.trip.startTime : null,
        directionId: v.trip.hasDirectionId() ? v.trip.directionId : null,
      ));
    }
    return VehicleSnapshot(feedTimestamp: _epoch(feed.header.timestamp.toInt()), vehicles: out);
  }
}
