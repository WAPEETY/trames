import 'package:maplibre_gl/maplibre_gl.dart';

/// Backend-neutral models. Every backend maps its own JSON into these.
///
/// Trip ids are always the *raw GTFS trip_id of the operator feed*
/// (e.g. Rome's `0#4103-14`), never a backend-specific wrapper, so data from
/// different sources (planner vs. vehicle GPS feed) can be joined.

enum PlaceKind { place, address, stop }

class Place {
  const Place({
    required this.name,
    required this.position,
    this.subtitle,
    this.isMyLocation = false,
    this.kind = PlaceKind.place,
    this.stopId,
    this.station = false,
  });
  final String name;
  final String? subtitle;
  final LatLng position;
  final bool isMyLocation;
  final PlaceKind kind;

  /// Backend stop id when [kind] is [PlaceKind.stop] (for its timetable).
  final String? stopId;

  /// A whole station (metro / rail) rather than one stop pole: its timetable
  /// covers all its platforms and both directions.
  final bool station;
}

/// Knobs a planner may honour. Backends map these to their own parameters
/// and ignore what they cannot do.
class PlanOptions {
  const PlanOptions({
    this.searchWindowMinutes = 30,
    this.legAlternatives = 3,
    this.maxTransfers,
    this.maxWalkMinutes,
    this.extraTransferMinutes,
  });

  /// How far after "now" departures are searched.
  final int searchWindowMinutes;

  /// Per transit leg, how many replacement connections to return.
  final int legAlternatives;
  final int? maxTransfers;

  /// Cap on the walk to the first stop and from the last stop.
  final int? maxWalkMinutes;

  /// Extra buffer reserved for every change.
  final int? extraTransferMinutes;
}

class Itinerary {
  Itinerary({
    required this.start,
    required this.end,
    required this.legs,
    required this.transfers,
    this.base,
    this.walkSlots = const {},
    this.walkOptions = const {},
  });

  final DateTime start;
  final DateTime end;
  final List<Leg> legs;
  final int transfers;

  /// When some rides were replaced by walking (see walk rules): the planner's
  /// original itinerary, so the trip view can still offer those rides.
  final Itinerary? base;

  /// Rides of [base] (by order among its transit legs) walked by default.
  final Set<int> walkSlots;

  /// For a walk leg (by index in [legs]) that replaces a ride: the lines that
  /// could do that stretch instead (swipe options), e.g. ["3BUS"].
  final Map<int, List<String>> walkOptions;

  bool get walkOnly => transitLegs.isEmpty;

  Duration get duration => end.difference(start);
  Iterable<Leg> get transitLegs => legs.where((l) => l.transit);
  bool get anyRealtime => transitLegs.any((l) => l.realtime);
  /// Delay of the final arrival: that of the last ride (walks just follow it).
  int? get arrivalDelaySeconds {
    final last = transitLegs.lastOrNull;
    return last?.arrivalDelaySeconds ?? last?.delaySeconds;
  }

  int get walkMinutes => legs.where((l) => !l.transit).fold(0, (m, l) => m + l.end.difference(l.start).inMinutes);

  /// Which line sequence this is ("211 › MEB"); used to group departures of the same route.
  String get signature => transitLegs.map((l) => l.routeShortName ?? l.mode).join(' › ');
}

/// Another connection that can replace a transit leg without breaking the
/// rest of the journey: the walk to its stop, the ride, the walk on to where
/// the journey continues (e.g. "or the 450 from the next stop").
class LegAlternative {
  LegAlternative(this.legs);

  /// Usually `[walk, ride, walk]`; the ride is the only transit leg.
  final List<Leg> legs;

  Leg get ride => legs.firstWhere((l) => l.transit);
  String get line => ride.routeShortName ?? ride.mode;
}

class Leg {
  Leg({
    required this.mode,
    required this.transit,
    required this.start,
    required this.end,
    required this.fromName,
    required this.toName,
    required this.from,
    required this.to,
    required this.points,
    required this.distanceMeters,
    this.routeShortName,
    this.headsign,
    this.tripId,
    this.backendTripId,
    this.realtime = false,
    this.delaySeconds,
    this.arrivalDelaySeconds,
    this.intermediateStops = 0,
    this.alternatives = const [],
  });

  /// WALK, BUS, TRAM, SUBWAY, RAIL, ...
  final String mode;
  final bool transit;
  final DateTime start;
  final DateTime end;
  final String fromName;
  final String toName;
  final LatLng from;
  final LatLng to;
  final List<LatLng> points;
  final double distanceMeters;
  final String? routeShortName;
  final String? headsign;

  /// Raw GTFS trip_id (see top of file).
  final String? tripId;

  /// The planner's own id for this trip (opaque), to ask the same backend
  /// for more about it, e.g. its full path.
  final String? backendTripId;
  final bool realtime;
  /// Departure delay at the boarding stop (live minus scheduled).
  final int? delaySeconds;

  /// Arrival delay at the alighting stop.
  final int? arrivalDelaySeconds;
  final int intermediateStops;
  final List<LegAlternative> alternatives;

  Duration get duration => end.difference(start);

  /// Same leg moved in time (used to re-time walks when a ride is swapped).
  Leg movedTo(DateTime newStart) => _copy(start: newStart, end: end.add(newStart.difference(start)));

  /// Same leg with a different set of alternatives.
  Leg withAlternatives(List<LegAlternative> alts) => _copy(alternatives: alts);

  Leg _copy({DateTime? start, DateTime? end, List<LegAlternative>? alternatives}) {
    return Leg(
      mode: mode,
      transit: transit,
      start: start ?? this.start,
      end: end ?? this.end,
      fromName: fromName,
      toName: toName,
      from: from,
      to: to,
      points: points,
      distanceMeters: distanceMeters,
      routeShortName: routeShortName,
      headsign: headsign,
      tripId: tripId,
      backendTripId: backendTripId,
      realtime: realtime,
      delaySeconds: delaySeconds,
      arrivalDelaySeconds: arrivalDelaySeconds,
      intermediateStops: intermediateStops,
      alternatives: alternatives ?? this.alternatives,
    );
  }
}

class Stop {
  Stop({
    required this.id,
    required this.name,
    required this.position,
    required this.distanceMeters,
    this.station = false,
    String? code,
  }) : code = code ?? stopCodeFromId(id);

  /// Backend stop id (opaque; only passed back to the same backend).
  final String id;

  /// Public stop number shown at the pole (e.g. "71502").
  final String code;
  final String name;
  final LatLng position;
  final int distanceMeters;

  /// A whole station (e.g. a metro station from search): its departures
  /// include all its platforms / same-name stops. Otherwise the board shows
  /// this exact stop only, i.e. one direction.
  final bool station;
}

/// Public code from a backend id when no code is given: the part after the
/// feed prefix ("it-Lazio-Rome_71502" -> "71502", "roma:71502" -> "71502").
String stopCodeFromId(String id) => id.split(RegExp(r'[_:]')).last;

class Departure {
  Departure({required this.time, required this.realtime, this.delaySeconds, this.tripId, this.backendTripId});
  final DateTime time;
  final bool realtime;
  final int? delaySeconds;
  final String? tripId;

  /// The planner's id for this trip, to ask for its route and stops.
  final String? backendTripId;
}

/// One line + direction at a stop, with its next departures.
class BoardRow {
  BoardRow({required this.stop, required this.line, required this.mode, required this.headsign, required this.next});
  final Stop stop;
  final String line;
  final String mode;
  final String headsign;
  final List<Departure> next;
}

class VehicleSnapshot {
  VehicleSnapshot({required this.feedTimestamp, required this.vehicles});
  final DateTime feedTimestamp;
  final List<Vehicle> vehicles;
}

class Vehicle {
  Vehicle({
    required this.id,
    required this.label,
    required this.tripId,
    required this.routeShortName,
    required this.position,
    required this.timestamp,
    this.bearing,
    this.startDate,
    this.startTime,
    this.directionId,
  });

  final String id;
  final String label;

  /// GTFS-RT trip descriptor: service day (YYYYMMDD) and first departure
  /// (HH:MM:SS, may exceed 24h) of the trip being run, and its direction.
  /// Together with [tripId] they identify the trip in a planner.
  final String? startDate;
  final String? startTime;
  final int? directionId;

  /// Raw GTFS trip_id (see top of file).
  final String? tripId;
  final String? routeShortName;
  final LatLng position;
  final DateTime timestamp;
  final double? bearing;
}

/// A walking route between two points, from the planner's street routing.
class WalkRoute {
  WalkRoute({required this.duration, required this.distanceMeters, required this.points});
  final Duration duration;
  final double distanceMeters;
  final List<LatLng> points;
}

/// Cache key for a walk between two points (~1 m precision).
String walkKey(LatLng a, LatLng b) =>
    '${a.latitude.toStringAsFixed(5)},${a.longitude.toStringAsFixed(5)}>${b.latitude.toStringAsFixed(5)},${b.longitude.toStringAsFixed(5)}';

/// One stop of a trip, with its (live when available) time there.
class TripStop {
  TripStop({required this.name, required this.position, this.time, this.scheduled, this.stopId});
  final String name;
  final LatLng position;
  final DateTime? time;
  final DateTime? scheduled;
  final String? stopId;

  int? get delaySeconds => time == null || scheduled == null ? null : time!.difference(scheduled!).inSeconds;
}

/// A whole vehicle run: its line, direction, path and every stop.
class TripInfo {
  TripInfo({
    required this.line,
    required this.mode,
    required this.headsign,
    required this.points,
    required this.stops,
    required this.realtime,
    this.directionId,
  });
  final String line;
  final String mode;
  final String headsign;
  final List<LatLng> points;
  final List<TripStop> stops;
  final bool realtime;
  final int? directionId;
}

/// Encoded polyline (Google format). OTP uses precision 5, MOTIS 6.
List<LatLng> decodePolyline(String s, {int precision = 5}) {
  final factor = precision == 5 ? 1e5 : precision == 6 ? 1e6 : 1e7;
  final out = <LatLng>[];
  int i = 0, lat = 0, lng = 0;
  while (i < s.length) {
    for (var k = 0; k < 2; k++) {
      int shift = 0, result = 0, b;
      do {
        b = s.codeUnitAt(i++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      // Zigzag decode with arithmetic, not `~`: on the web Dart bitwise ops are
      // unsigned 32-bit, so `~x` would be a huge positive number there.
      final d = (result & 1) != 0 ? -(result >> 1) - 1 : (result >> 1);
      if (k == 0) {
        lat += d;
      } else {
        lng += d;
      }
    }
    out.add(LatLng(lat / factor, lng / factor));
  }
  return out;
}

/// Part of a vehicle's path between where it is now and [stop]: starts at
/// [vehicle], follows [path] and ends at the path point nearest [stop].
/// Empty when the vehicle is already at or past the stop.
List<LatLng> approachPath(List<LatLng> path, LatLng vehicle, LatLng stop) {
  if (path.length < 2) return const [];
  double d2(LatLng a, LatLng b) {
    final dy = a.latitude - b.latitude;
    final dx = (a.longitude - b.longitude) * 0.745; // cos(42°): Rome-ish
    return dx * dx + dy * dy;
  }

  int nearest(LatLng p, int end) {
    var best = 0;
    for (var i = 1; i < end; i++) {
      if (d2(path[i], p) < d2(path[best], p)) best = i;
    }
    return best;
  }

  final j = nearest(stop, path.length);
  // Search the vehicle only before the stop: on loop routes the path passes
  // near the same place twice.
  final i = nearest(vehicle, j + 1);
  if (i >= j) return const [];
  return [vehicle, ...path.sublist(i + 1, j + 1)];
}
