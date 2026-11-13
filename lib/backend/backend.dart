import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:maplibre_gl/maplibre_gl.dart';

import 'cities.dart';
import 'models.dart';

export 'cities.dart';
export 'models.dart';

/// The app talks to transit data only through these four capabilities.
/// Each can come from a different source; [TransitBackend] bundles one of each.
///
/// To self-host later, implement (or reuse) whichever pieces you replace and
/// add a factory in `config.dart`. A self-hosted MOTIS is just
/// `MotisClient(baseUrl: ...)`; an OpenTripPlanner server would need an
/// `OtpClient implements TripPlanner, StopBoards`.

abstract interface class TripPlanner {
  /// Itineraries departing from now on, in any order. [options] are hints;
  /// a backend ignores the ones it does not support.
  Future<List<Itinerary>> plan(LatLng from, LatLng to, {PlanOptions options = const PlanOptions()});
}

abstract interface class PlaceSearch {
  Future<List<Place>> search(String query, {LatLng? near});
}

abstract interface class StopBoards {
  /// Stops around [p], nearest first, with distance filled in.
  Future<List<Stop>> nearbyStops(LatLng p);

  /// Stops inside [area] (the visible map), nearest to [from] first, with
  /// distance from [from] filled in.
  Future<List<Stop>> stopsInArea(LatLngBounds area, {required LatLng from});

  /// One row per line + direction with upcoming departures.
  Future<List<BoardRow>> board(Stop stop);
}

abstract interface class TripDetails {
  /// Full run of a trip by the planner's trip id.
  Future<TripInfo> trip(String backendTripId);

  /// The planner's id for the trip a live [vehicle] is running, if it can be
  /// derived (needs the GTFS-RT start date/time), else null.
  String? tripIdForVehicle(Vehicle vehicle);
}

abstract interface class WalkRouter {
  /// Street walking route from [from] to [to], or null if none.
  Future<WalkRoute?> walk(LatLng from, LatLng to);
}

/// Synchronous view over walks fetched so far (shared by the route search and
/// the trip view), plus batched fetching of the missing ones.
class WalkCache {
  WalkCache(this.router);
  final WalkRouter router;
  final _known = <String, WalkRoute?>{};

  /// The route if already fetched (null if unknown or none exists).
  WalkRoute? lookup(LatLng from, LatLng to) => _known[walkKey(from, to)];
  bool has(LatLng from, LatLng to) => _known.containsKey(walkKey(from, to));

  /// Fetches up to [max] of [pairs] not known yet, in parallel.
  Future<void> fetch(Iterable<(LatLng, LatLng)> pairs, {int max = 6}) async {
    final todo = <String, (LatLng, LatLng)>{};
    for (final p in pairs) {
      final k = walkKey(p.$1, p.$2);
      if (!_known.containsKey(k) && todo.length < max) todo[k] = p;
    }
    await Future.wait(todo.entries.map((e) async {
      try {
        _known[e.key] = await router.walk(e.value.$1, e.value.$2);
      } catch (_) {
        // leave unknown: retried next time
      }
    }));
  }
}

abstract interface class TripPaths {
  /// The whole path of the vehicle running [leg]'s trip, first stop to last.
  Future<List<LatLng>> tripPath(Leg leg);
}

abstract interface class VehicleFeed {
  /// Live vehicle positions; [Vehicle.tripId] is the raw GTFS trip_id.
  Future<VehicleSnapshot> vehicles();
}

/// What [ReturnEstimator] needs from a backend.
abstract interface class ReturnSource {
  /// Trips leaving [stopId] (a terminus) from now on, any line.
  Future<List<TerminusRun>> departuresFrom(String stopId);

  /// Where and when the trip [v] is running ends, best estimate (live where
  /// known); null when the backend doesn't know the trip.
  Future<TripEnd?> tripEnd(Vehicle v);
}

/// A trip leaving its first stop.
class TerminusRun {
  const TerminusRun({
    required this.tripId,
    required this.line,
    required this.scheduled,
    required this.realtime,
    this.directionId,
  });

  /// Raw GTFS trip id.
  final String tripId;
  final String line;

  /// Timetabled departure from the terminus.
  final DateTime scheduled;
  final bool realtime;
  final int? directionId;
}

/// Last stop of a running trip and when the bus should get there.
class TripEnd {
  const TripEnd({required this.position, required this.time});
  final LatLng position;
  final DateTime time;
}

class TransitBackend {
  const TransitBackend({
    required this.name,
    required this.planner,
    required this.places,
    required this.stops,
    this.vehicles,
    this.city,
    this.paths,
    this.trips,
    this.walks,
    this.returns,
  });

  final String name;
  final TripPlanner planner;
  final PlaceSearch places;
  final StopBoards stops;
  /// Live GPS positions; only where the city has a feed (see CityConfig).
  final VehicleFeed? vehicles;

  /// The configured city this backend serves, or null (Transitous only).
  final CityConfig? city;

  /// Optional: lets the map show where a live vehicle still has to go.
  final TripPaths? paths;

  /// Optional: line view (a trip's route, stops, and the line's live buses).
  final TripDetails? trips;

  /// Optional: street walking routes, to offer walking instead of short rides.
  final WalkRouter? walks;

  /// Optional: buses coming back from the other direction (needs [vehicles]).
  final ReturnSource? returns;
}

/// Shared helpers for implementations.
const kUserAgent = 'trames/0.1';

/// Request headers. Browsers forbid setting User-Agent (and log an error if
/// you try), so web builds send none.
Map<String, String> get kHeaders => kIsWeb ? const {} : const {'User-Agent': kUserAgent};

double distanceMeters(LatLng a, LatLng b) {
  const r = 6371000.0;
  final p1 = a.latitude * math.pi / 180, p2 = b.latitude * math.pi / 180;
  final dp = p2 - p1, dl = (b.longitude - a.longitude) * math.pi / 180;
  final h = math.sin(dp / 2) * math.sin(dp / 2) + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.asin(math.sqrt(h));
}

/// Groups departures at one stop into one row per line + direction.
List<BoardRow> groupDepartures(
  Stop stop,
  Iterable<({String line, String mode, String headsign, Departure departure})> items,
) {
  final rows = <String, BoardRow>{};
  for (final i in items) {
    final key = '${i.line}|${i.headsign}';
    (rows[key] ??= BoardRow(stop: stop, line: i.line, mode: i.mode, headsign: i.headsign, next: []))
        .next
        .add(i.departure);
  }
  for (final r in rows.values) {
    r.next.sort((a, b) => a.time.compareTo(b.time));
  }
  return rows.values.toList();
}

/// Removes departures whose bus has already gone by: timetable-only (no
/// prediction for this stop) while its trip is out on the road in the live
/// feed ([runningTrips]: raw GTFS trip ids and run keys, see
/// [indexVehicles]). The operator only predicts the
/// stops still ahead, so a running trip with no prediction here has passed
/// it, e.g. a bus 13 minutes early, still listed at its timetable time.
/// Rows left with no departure are dropped.
List<BoardRow> dropPassedDepartures(List<BoardRow> rows, Set<String> runningTrips) {
  if (runningTrips.isEmpty) return rows;
  bool running(Departure d) => runningTrips.contains(d.tripId) || runningTrips.contains(d.runKey);
  return [
    for (final r in rows)
      if (r.next.where((d) => d.realtime || !running(d)).toList() case final next
          when next.isNotEmpty)
        next.length == r.next.length ? r : BoardRow(stop: r.stop, line: r.line, mode: r.mode, headsign: r.headsign, next: next),
  ];
}

/// One row per bus (instead of per line), soonest first: for a single
/// stop's board, so every live bus shows as live.
List<BoardRow> boardPerDeparture(List<BoardRow> rows) => [
      for (final r in rows)
        for (final d in r.next) BoardRow(stop: r.stop, line: r.line, mode: r.mode, headsign: r.headsign, next: [d]),
    ]..sort((a, b) => a.next.first.time.compareTo(b.next.first.time));

/// Moves departures the app estimated itself ([Certainty.estimated]) to
/// their estimated time; rows stay soonest first.
List<BoardRow> applyReturnEstimates(List<BoardRow> rows, Map<String, ReturnEstimate> returns) {
  if (returns.isEmpty) return rows;
  return [
    for (final r in rows)
      BoardRow(stop: r.stop, line: r.line, mode: r.mode, headsign: r.headsign, next: [
        for (final d in r.next)
          if (returns[d.tripId] case ReturnEstimate(certainty: Certainty.estimated, :final delay) when !d.realtime)
            d.at(d.time.add(delay))
          else
            d,
      ]..sort((a, b) => a.time.compareTo(b.time))),
  ];
}

/// Orders search results for someone at [reference]: everything within
/// [localKm] first, in the backend's own relevance order (name match), then
/// the rest nearest first (nearby towns before far-away cities). Stable, so
/// equally near results keep their relevance order.
List<Place> rankByProximity(List<Place> places, LatLng reference, {double localKm = 25}) {
  final local = <Place>[];
  final far = <(double, int, Place)>[];
  for (var i = 0; i < places.length; i++) {
    final d = distanceMeters(reference, places[i].position) / 1000;
    if (d <= localKm) {
      local.add(places[i]);
    } else {
      far.add((d, i, places[i]));
    }
  }
  far.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  return [...local, for (final f in far) f.$3];
}
