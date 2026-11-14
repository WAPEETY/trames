import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;

import 'backend/backend.dart';
import 'backend/config.dart';
import 'backend/estimated_rides.dart';
import 'backend/live_connection.dart';
import 'backend/motis.dart' show MotisClient;
import 'backend/route_search.dart';
import 'backend/trip_variants.dart';
import 'area_buses.dart';
import 'attribution.dart';
import 'favorites.dart';
import 'l10n.dart';
import 'line_view.dart';
import 'live_buses.dart';
import 'route_picker.dart';
import 'sheet_widgets.dart';
import 'swipe_slot.dart';

/// Free vector tiles from OpenFreeMap (OSM data, no API key).
const kMapStyleLight = 'https://tiles.openfreemap.org/styles/positron';
const kMapStyleDark = 'https://tiles.openfreemap.org/styles/fiord';

const kLegPalette = ['#D81B60', '#1E88E5', '#43A047', '#FB8C00', '#8E24AA', '#00897B'];
const kWalkColor = '#9E9E9E';

/// Sheet peek: drag handle + destination search bar.
const kSheetPeek = 128.0;

/// Below this zoom the map shows no stops and the sheet only the search bar.
const kMinStopsZoom = 14.0;

/// From this zoom up, stop names are drawn next to the pins.
const kStopNamesZoom = 16.0;

/// Wait this long after the map stops moving before loading its stops.
const kAreaIdleDelay = Duration(milliseconds: 600);

/// At most this many stops get their departures loaded (nearest first).
const kMaxBoardStops = 8;

/// At most this many stop pins drawn at once.
const kMaxStopPins = 80;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// The configured city around the map / you (null: Transitous only).
  CityConfig? city = kCities.first;
  late TransitBackend backend = createBackend(city: city);

  /// Where to start without location: the city's, else the first city's.
  Place get _fallback => (city ?? kCities.first).fallbackCenter;
  final sheet = M3EBottomSheetController();
  final toSearch = M3ESearchController();
  final fromSearch = M3ESearchController();
  MapLibreMapController? map;
  bool styleReady = false;
  bool locationGranted = false;
  M3EBottomSheetValue sheetValue = M3EBottomSheetValue.collapsed;

  LatLng? here;
  // Named in didChangeDependencies, once the locale is known.
  Place from = Place(name: '', position: kCities.first.fallbackCenter.position, isMyLocation: true);
  Place? to;

  // Departures for the visible map area (idle state).
  List<BoardRow> nearby = [];

  /// Tramite's view of the journeys' rides, by raw trip id: how sure each
  /// is, its inferred time, its bus. Only for rides Tramite covers; kept in
  /// step with the shown journeys by [_syncLegTopics].
  final Map<String, TramiteRow> _legRows = {};
  late final LiveTopics _legTopics = LiveTopics(live);

  /// Timetable-only rides a known bus should run (from [_legRows]), moved to
  /// that bus's time by applyEstimatedRides.
  Map<String, ReturnEstimate> routeReturns = {};

  /// Board rows from Transitous (stops Tramite doesn't cover), and from
  /// Tramite by stop id (pushed), to rebuild [nearby].
  List<BoardRow> _transitousRows = [];
  final Map<String, List<BoardRow>> _tramiteRows = {};
  late final LiveTopics _boardTopics = LiveTopics(live);

  /// The open line's buses.
  late final LiveTopics _lineTopics = LiveTopics(live);

  /// How sure a ride's time is: what Tramite says for rides it covers;
  /// otherwise live (counted as on its way: no way to tell) or timetable.
  Certainty _certainty(bool realtime, String? tripId) =>
      (tripId == null ? null : _legRows[tripId])?.departure.certainty ??
      certaintyOf(realtime: realtime, tripId: tripId, returns: routeReturns);

  Certainty _depCertainty(Departure d) => d.certainty ?? _certainty(d.realtime, d.tripId);

  /// Follows, through Tramite, the rides of the shown journeys (the
  /// selected one, else the whole list): one topic per ride at its boarding
  /// stop. Rides Tramite doesn't cover keep Transitous's data.
  void _syncLegTopics() {
    final legs = selected?.transitLegs ?? [for (final it in _routeItineraries) ...it.transitLegs];
    final wanted = <String, void Function(Object?)>{};
    final trips = <String>{};
    for (final l in legs) {
      final stop = l.fromStopId, trip = l.backendTripId, raw = l.tripId, prefix = tramite.prefixOf(l.backendTripId);
      if (stop == null || trip == null || raw == null || prefix == null || !tramite.covers(stop)) continue;
      trips.add(raw);
      final line = l.routeShortName;
      final topic = TramiteClient.departuresTopic(stop,
          tripId: trip, lineId: line == null ? null : TramiteClient.lineId(prefix, line));
      wanted[topic] = (data) {
        if (!mounted) return;
        final row = TramiteClient.parseRows(data).firstOrNull;
        setState(() {
          if (row == null) {
            _legRows.remove(raw);
          } else {
            _legRows[raw] = row;
          }
          _applyLegRows();
        });
      };
    }
    _legTopics.sync(wanted);
    _legRows.removeWhere((trip, _) => !trips.contains(trip));
    _applyLegRows();
  }

  /// New ride data: inferred times into [routeReturns] (re-planning the
  /// list), the selected journey's buses onto the map.
  void _applyLegRows() {
    routeReturns = {
      for (final MapEntry(key: trip, value: r) in _legRows.entries)
        if (r.inferred) trip: ReturnEstimate(r.departure.certainty!, delay: r.departure.time.difference(r.scheduled)),
    };
    final it = selected;
    if (it == null) {
      if (to != null) routes = _buildRoutes();
      return;
    }
    final colors = _legColors(it);
    tracker.show({
      for (final l in it.transitLegs)
        if (_legRows[l.tripId]?.bus case final bus?) l.tripId!: (vehicle: bus, color: colors[l.tripId] ?? _lineColor),
    });
    _drawApproach();
  }

  /// [nearby] from the fetched rows: one stop lists every bus, nearby one
  /// row per line + direction (from whichever stop has it soonest).
  List<BoardRow> _buildNearby() {
    final rows = [..._transitousRows, for (final r in _tramiteRows.values) ...r];
    if (filterStop != null) return boardPerDeparture(rows);
    final best = <String, BoardRow>{};
    for (final r in rows) {
      final k = '${r.line}|${r.headsign}';
      if (!best.containsKey(k) || r.next.first.time.isBefore(best[k]!.next.first.time)) best[k] = r;
    }
    return best.values.toList()..sort((a, b) => a.next.first.time.compareTo(b.next.first.time));
  }
  List<Stop> nearbyStops = [];
  final Map<String, Stop> stopById = {};
  bool nearbyLoading = true;

  /// The map was moved away from you: "Departures in this area".
  bool areaMode = false;

  /// Zoomed out past [kMinStopsZoom]: no stops, no departures.
  bool zoomedOut = false;

  /// Tapped stop: departures from this stop only.
  Stop? filterStop;
  Timer? idleDebounce;

  /// Line view (a line's route, stops and live buses), when open.
  LineState? line;
  int _areaSeq = 0;

  // Routes.
  /// Walking routes fetched so far, shared by the route search and the trip view.
  /// Favourite stops and destinations (on the device).
  final favorites = FavoritesStore()..load();
  late final WalkCache? walkCache = backend.walks == null ? null : WalkCache(backend.walks!);
  late final RouteSearch routeSearch = RouteSearch(backend.planner, walks: walkCache);
  List<RouteGroup> routes = [];

  /// The planner's itineraries behind [routes], before estimates (purple
  /// rides) are applied, to re-plan them when new estimates arrive.
  List<Itinerary> _routeItineraries = [];

  /// [routes] from [_routeItineraries] with [routeReturns] applied: late
  /// (purple) rides moved and connections re-planned, then grouped and
  /// ranked again; routes that can't make a connection go last.
  List<RouteGroup> _buildRoutes() {
    if (!routeReturns.values.any((e) => e.certainty == Certainty.estimated)) return routeSearch.group(_routeItineraries);
    final groups = routeSearch.group([
      for (final it in _routeItineraries) applyEstimatedRides(it, routeReturns, walks: walkCache),
    ]);
    return [...groups.where((g) => !g.best.missedConnection), ...groups.where((g) => g.best.missedConnection)];
  }
  Itinerary? selected;

  /// Swappable rides of the selected trip; [selected] is its current composition.
  TripVariants? variants;

  /// Full vehicle paths of the selected trip's rides, by GTFS trip id.
  final Map<String, List<LatLng>> tripPaths = {};
  bool planning = false;
  String? error;

  Timer? refreshTimer;
  Timer? clock;

  /// Buses of the selected journey or the open line, on the map.
  late final LiveBusTracker tracker = LiveBusTracker(
    onFrame: (g) async {
      if (map != null && styleReady) await map!.setGeoJsonSource('buses', g);
    },
  );

  /// Every bus around the map while browsing (no journey or line open).
  late final AreaBuses areaBuses = AreaBuses(
    connection: live,
    tracker: LiveBusTracker(onFrame: (g) async {
      if (map != null && styleReady) await map!.setGeoJsonSource('area-buses', g);
    }),
  );

  /// The live stream is closed while the app is in the background.
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onHide: live.pause,
    onShow: () {
      live.resume();
      _updateAreaBuses();
    },
  );

  /// Leaving the browsing view (journeys or a line open): no more area
  /// buses or stop boards followed.
  void _leaveBrowsing() {
    areaBuses.hide();
    _boardTopics.clear();
    _tramiteRows.clear();
  }

  /// Shows the buses around the visible map when browsing, hides them when
  /// a route or a line is open (those show their own buses).
  Future<void> _updateAreaBuses() async {
    final m = map;
    if (m == null || !styleReady) return;
    if (to != null || line != null || selected != null) {
      areaBuses.hide();
      return;
    }
    try {
      final view = await m.getVisibleRegion();
      if (!mounted || to != null || line != null) return;
      areaBuses.defaultColor = _lineColor;
      areaBuses.show(view, m.cameraPosition?.zoom ?? 15);
    } catch (_) {}
  }

  /// The "My location" origin at [p], named in the current language.
  Place _myLocation(LatLng p) => Place(name: context.l10n.myLocation, position: p, isMyLocation: true);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Name "My location" in the current language (also after a change).
    if (from.isMyLocation && from.name != context.l10n.myLocation) {
      final shown = fromSearch.text.isEmpty || fromSearch.text == from.name;
      from = _myLocation(from.position);
      if (shown) fromSearch.text = from.name;
    }
  }

  @override
  void initState() {
    super.initState();
    _lifecycle;
    // What Tramite covers decides, per stop and ride, where live data comes
    // from; until it answers, Transitous.
    tramite.loadCoverage().then((_) {
      if (mounted) _refreshArea(silent: true);
    });
    _initLocation();
    // Nearby boards every 30 s while idle; routes every 60 s while listing.
    refreshTimer = Timer.periodic(const Duration(seconds: 30), (t) {
      tramite.loadCoverage(); // no-op once known; retries while unreachable
      if (line != null) {
        // the line's buses are pushed
      } else if (to == null) {
        _refreshArea(silent: true);
      } else if (selected == null && !planning && t.tick.isEven) {
        _plan(silent: true);
      }
    });
    clock = Timer.periodic(const Duration(seconds: 15), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    clock?.cancel();
    idleDebounce?.cancel();
    _lifecycle.dispose();
    _leaveBrowsing();
    _legTopics.clear();
    _lineTopics.clear();
    toSearch.dispose();
    fromSearch.dispose();
    favorites.dispose();
    sheet.dispose();
    super.dispose();
  }

  Future<void> _initLocation() async {
    try {
      if (await Geolocator.isLocationServiceEnabled()) {
        var p = await Geolocator.checkPermission();
        if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
        if (p != LocationPermission.denied && p != LocationPermission.deniedForever) {
          setState(() => locationGranted = true);
          final pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(timeLimit: Duration(seconds: 10)),
          );
          here = LatLng(pos.latitude, pos.longitude);
          _switchCityFor(here!);
          from = _myLocation(here!);
          map?.animateCamera(CameraUpdate.newLatLngZoom(here!, 15.5));
        }
      }
    } catch (_) {
      // Fall back to Termini (also handy when testing from outside Rome).
    }
    if (here == null) {
      from = _fallback;
      fromSearch.text = from.name;
    }
    _refreshArea();
  }

  // ---------- data ----------

  /// Map stopped moving: after [kAreaIdleDelay] load what's in view.
  void _onCameraIdle() {
    _updateAreaBuses();
    if (to != null || line != null) return; // the area list isn't shown
    idleDebounce?.cancel();
    idleDebounce = Timer(kAreaIdleDelay, _refreshArea);
  }

  /// Loads stops in the visible map area (pins) and departures from the
  /// nearest of them, or from [filterStop] only when one is selected.
  Future<void> _refreshArea({bool silent = false}) async {
    _updateAreaBuses();
    final m = map;
    if (m == null || !styleReady || to != null || line != null) return;
    final seq = ++_areaSeq;
    final camera = m.cameraPosition;
    final zoom = camera?.zoom ?? 15;

    if (zoom < kMinStopsZoom) {
      // Only the search bar is left: drop the sheet to its lowest height
      // (dragging is disabled while in this state, see build()).
      if (!zoomedOut) sheet.animateTo(M3EBottomSheetValue.preview);
      _boardTopics.clear();
      setState(() {
        zoomedOut = true;
        nearbyStops = [];
        nearby = [];
        _tramiteRows.clear();
        _transitousRows = [];
        nearbyLoading = false;
      });
      _drawNearbyStops();
      return;
    }

    final center = camera?.target ?? here ?? _fallback.position;
    _switchCityFor(center);
    final home = here ?? _fallback.position;
    if (zoomedOut) sheet.animateTo(M3EBottomSheetValue.collapsed); // content is back
    setState(() {
      zoomedOut = false;
      // "near you" while the view is still around your position.
      areaMode = distanceMeters(center, home) > 250;
      if (!silent) nearbyLoading = true;
    });

    try {
      final area = await _visibleArea(m);
      final reference = areaMode ? center : home;
      final stops = await backend.stops.stopsInArea(area, from: reference);
      if (seq != _areaSeq || !mounted) return;
      final pins = stops.take(kMaxStopPins).toList();
      final boardStops = filterStop != null ? [filterStop!] : pins.take(kMaxBoardStops).toList();
      // Stops Tramite covers are followed there (pushed, all colours); the
      // rest are asked to Transitous on each refresh. A station mixes
      // operators: its departures from stops Tramite covers come from
      // Tramite too, listed under the station.
      final followed = <String, Stop>{}; // Tramite stop id -> stop its rows show under
      final asked = <Stop>[];
      for (final s in boardStops) {
        if (!s.station && tramite.covers(s.id)) {
          followed[s.id] = s;
        } else {
          asked.add(s);
        }
      }
      final boards = await Future.wait(asked.map((s) => backend.stops.board(s).catchError((_) => <BoardRow>[])));
      if (seq != _areaSeq || !mounted) return;
      final rows = <BoardRow>[];
      for (final (i, s) in asked.indexed) {
        for (final r in boards[i]) {
          final next = <Departure>[];
          for (final d in r.next) {
            final id = d.stopId;
            if (s.station && id != null && tramite.covers(id)) {
              followed[id] = s;
            } else {
              next.add(d);
            }
          }
          if (next.isNotEmpty) rows.add(BoardRow(stop: r.stop, line: r.line, mode: r.mode, headsign: r.headsign, next: next));
        }
      }
      setState(() {
        nearbyStops = pins;
        stopById
          ..clear()
          ..addEntries(pins.map((s) => MapEntry(s.id, s)));
        _transitousRows = rows;
        _tramiteRows.removeWhere((id, _) => !followed.containsKey(id));
        nearby = _buildNearby();
        error = null;
      });
      _boardTopics.sync({
        for (final MapEntry(key: id, value: stop) in followed.entries)
          TramiteClient.departuresTopic(id): (data) {
            if (!mounted) return;
            setState(() {
              _tramiteRows[id] = TramiteClient.parseBoard(data, stop);
              nearby = _buildNearby();
            });
          },
      });
      _drawNearbyStops();
    } catch (e) {
      if (mounted && !silent && seq == _areaSeq) setState(() => error = '$e');
    } finally {
      if (mounted && seq == _areaSeq) setState(() => nearbyLoading = false);
    }
  }

  /// The part of the map you can actually see: the visible region minus the
  /// strip hidden under the sheet (bottom content inset).
  Future<LatLngBounds> _visibleArea(MapLibreMapController m) async {
    final h = MediaQuery.sizeOf(context).height;
    final hidden = (_mapInsets().bottom / h).clamp(0.0, 0.8);
    final r = await m.getVisibleRegion();
    final latSpan = r.northeast.latitude - r.southwest.latitude;
    return LatLngBounds(
      southwest: LatLng(r.southwest.latitude + latSpan * hidden, r.southwest.longitude),
      northeast: r.northeast,
    );
  }

  void _filterTo(Stop stop) {
    HapticFeedback.selectionClick();
    setState(() {
      filterStop = stop;
      nearby = [];
    });
    _drawNearbyStops();
    _refreshArea();
  }

  void _clearFilter() {
    setState(() {
      filterStop = null;
      nearby = [];
    });
    _drawNearbyStops();
    _refreshArea();
  }

  Future<void> _plan({bool silent = false}) async {
    final dest = to;
    if (dest == null) return;
    _leaveBrowsing();
    setState(() {
      planning = true;
      error = null;
      if (!silent) routes = [];
    });
    try {
      // Several planner profiles merged and grouped by line sequence,
      // groups ordered by earliest arrival (see RouteSearch).
      final list = await routeSearch.search(from.position, dest.position);
      if (!mounted || to != dest) return;
      setState(() {
        _routeItineraries = [for (final g in list) ...g.options];
        // Then Tramite's view of the rides it covers, pushed as it changes:
        // colours, and inferred times (re-planned around). Rides still
        // listed keep what is known until then (no flicker).
        _syncLegTopics();
        routes = _buildRoutes();
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => planning = false);
    }
  }

  // ---------- map ----------

  /// Fetch the full path of each ride (cached per trip by the backend).
  void _loadTripPaths(Itinerary it) {
    final paths = backend.paths;
    if (paths == null) return;
    for (final leg in it.transitLegs) {
      final id = leg.tripId;
      if (id == null || tripPaths.containsKey(id)) continue;
      paths.tripPath(leg).then((p) {
        if (!mounted || p.isEmpty) return;
        tripPaths[id] = p;
        _drawApproach();
      });
    }
  }

  /// Dotted line from each tracked vehicle to the stop where you board it,
  /// only while it hasn't reached that stop yet.
  Future<void> _drawApproach() async {
    if (!styleReady) return;
    final it = selected;
    final features = <Map<String, dynamic>>[];
    if (it != null) {
      for (final leg in it.transitLegs) {
        final path = tripPaths[leg.tripId];
        final bus = tracker.buses[leg.tripId];
        if (path == null || bus == null) continue;
        final seg = approachPath(path, bus.vehicle.position, leg.from);
        if (seg.length < 2) continue;
        features.add({
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': [for (final p in seg) [p.longitude, p.latitude]],
          },
          'properties': {'color': _colorHexFor(it, leg)},
        });
      }
    }
    await map!.setGeoJsonSource('approach', _collection(features));
  }

  // ---------- line view ----------

  String get _lineColor => _hex(Theme.of(context).colorScheme.primary);

  /// Opens the line view for [name]. [tripId] (a tapped departure, in
  /// Transitous form) picks the direction to show; otherwise the first
  /// direction with a live bus. [lineId] is the line in Tramite (e.g.
  /// "it-Lazio-Rome_85"), known from line search; else derived from [tripId].
  /// Without Tramite for the line: its route only, no live buses.
  Future<void> _openLine({required String name, required String mode, String? tripId, String? lineId, RunHint? hint}) async {
    final trips = backend.trips;
    if (trips == null) return;
    HapticFeedback.selectionClick();
    if (selected != null) _deselect();
    if (to != null) _clearDestination();
    final state = LineState(name, mode)..tripId = tripId;
    if (tripId != null && hint != null) state.runHints[tripId] = hint;
    setState(() => line = state);
    if (sheetValue == M3EBottomSheetValue.preview) sheet.animateTo(M3EBottomSheetValue.collapsed);
    _drawNearbyStops();
    _leaveBrowsing();
    if (tripId != null) _loadLineTrip(tripId);

    final prefix = lineId == null ? tramite.prefixOf(tripId) : null;
    final id = lineId ?? (prefix == null ? null : TramiteClient.lineId(prefix, name));
    if (id == null) {
      if (tripId == null) setState(() => state.error = context.l10n.errorNoLiveBusesForLine);
      return;
    }
    // The line's buses, pushed: drawn, and one trip per direction for the
    // direction switch (the first one shown if no departure picked one).
    _lineTopics.sync({
      TramiteClient.lineTopic(id): (data) {
        if (!mounted || line != state) return;
        final buses = TramiteClient.parseVehicles(data);
        tracker.show({for (final b in buses) b.vehicle.tripId ?? b.vehicle.id: (vehicle: b.vehicle, color: _lineColor)});
        for (final b in buses) {
          final t = b.vehicle.backendTripId, stop = b.vehicle.stopId;
          if (t == null) continue;
          state.directions.putIfAbsent(b.vehicle.directionId ?? 0, () => t);
          // The stop it heads to, now: where the planner can find the run.
          if (stop != null) state.runHints[t] = (stopId: stop, at: DateTime.now());
        }
        if (state.tripId == null) {
          final first = state.directions.values.firstOrNull;
          if (first != null) {
            _loadLineTrip(first);
          } else {
            setState(() => state.error = context.l10n.errorNoBusRunning(name));
          }
        } else {
          setState(() {});
        }
        _drawApproach();
      },
    });
  }

  Future<void> _loadLineTrip(String id) async {
    final state = line;
    final trips = backend.trips;
    if (state == null || trips == null) return;
    setState(() {
      state.tripId = id;
      state.trip = null;
      state.error = null;
    });
    try {
      final t = await _tripOrSameRun(trips, id, state);
      if (line != state) return;
      setState(() => state.trip = t);
      _drawLine();
      _fitTo(t.points);
    } catch (e) {
      if (line == state) setState(() => state.error = context.l10n.errorLoadLine('$e'));
    }
  }

  /// The trip from the planner; if it doesn't know the id (it came from
  /// Tramite, whose timetable can be a newer version), the same run under
  /// the planner's id, found where the hint says it passes.
  Future<TripInfo> _tripOrSameRun(TripDetails trips, String id, LineState state) async {
    try {
      return await trips.trip(id);
    } catch (_) {
      final hint = state.runHints[id];
      if (hint == null) rethrow;
      final same = await trips.sameRun(id, stopId: hint.stopId, at: hint.at, line: state.name);
      if (same == null || same == id) rethrow;
      return trips.trip(same);
    }
  }

  /// A bus tapped on the map while browsing: its trip in the line view, as
  /// when tapping a departure. Its next stop, now, is where the planner can
  /// find the run if the trip id is from another timetable version.
  void _openBus(String vehicleId) {
    final v = areaBuses.tracker.buses[vehicleId]?.vehicle;
    final name = v?.routeShortName;
    if (v == null || name == null) return;
    final stop = v.stopId;
    _openLine(
      name: name,
      mode: 'BUS',
      tripId: v.backendTripId,
      hint: stop == null ? null : (stopId: stop, at: DateTime.now()),
    );
  }

  /// Trip id of the other direction, if a live bus is running it.
  String? _otherDirection() {
    final state = line;
    final dir = state?.trip?.directionId;
    if (state == null || state.directions.length < 2) return null;
    return state.directions.entries.where((e) => e.key != dir).map((e) => e.value).firstOrNull;
  }

  void _closeLine() {
    if (line == null) return;
    setState(() => line = null);
    _lineTopics.clear();
    tracker.clear();
    _drawLine();
    _drawNearbyStops();
    _refreshArea();
  }

  Future<void> _drawLine() async {
    if (!styleReady) return;
    final t = line?.trip;
    final color = _lineColor;
    await map!.setGeoJsonSource(
        'line',
        _collection([
          if (t != null)
            {
              'type': 'Feature',
              'geometry': {
                'type': 'LineString',
                'coordinates': [for (final p in t.points) [p.longitude, p.latitude]],
              },
              'properties': {'color': color},
            },
        ]));
    await map!.setGeoJsonSource(
        'line-stops',
        _collection([
          if (t != null)
            for (final st in t.stops) _point(st.position, {'color': color, 'name': titleCase(st.name)}),
        ]));
  }

  /// Search result "timetable" button: show that stop's departures, like
  /// tapping its pin.
  void _openStopTimetable(Place p) {
    if (line != null) _closeLine();
    if (to != null) _clearDestination();
    final stop = Stop(
      id: p.stopId!,
      name: p.name,
      position: p.position,
      distanceMeters: here == null ? 0 : distanceMeters(here!, p.position).round(),
      // Metro / rail stations show all platforms (Termini: A + B); a bus or
      // tram stop shows just this pole, i.e. one direction.
      station: p.station,
    );
    setState(() {
      filterStop = stop;
      nearby = [];
    });
    if (sheetValue == M3EBottomSheetValue.preview) sheet.animateTo(M3EBottomSheetValue.collapsed);
    // Moving there triggers the area reload, which honours the filter; load
    // right away too in case the camera is already there (no move, no idle).
    map?.animateCamera(CameraUpdate.newLatLngZoom(p.position, 17));
    _refreshArea();
  }

  /// Picks the configured city around [p] (or none: Transitous only) and
  /// rebuilds the city-specific backend parts. Caches and favourites stay.
  void _switchCityFor(LatLng p) {
    final next = cityAt(p);
    if (next?.id == city?.id) return;
    setState(() {
      city = next;
      backend = createBackend(city: next);
    });
  }

  Future<void> _onStyleLoaded() async {
    final m = map!;
    final primary = _hex(Theme.of(context).colorScheme.primary);
    const empty = {'type': 'FeatureCollection', 'features': []};
    final labelColor = _hex(Theme.of(context).colorScheme.onSurface);
    final haloColor = _hex(Theme.of(context).colorScheme.surface);
    await m.addGeoJsonSource('nearby', empty, promoteId: 'id');
    for (final id in ['line', 'line-stops', 'approach', 'route', 'stops', 'endpoints', 'buses']) {
      await m.addGeoJsonSource(id, empty);
    }
    // Feature id = vehicle id: a tapped bus opens its trip.
    await m.addGeoJsonSource('area-buses', empty, promoteId: 'id');
    // Stop pins: tappable (filters departures to that stop); the selected one
    // is bigger.
    await m.addCircleLayer('nearby', 'nearby-circle',
        CircleLayerProperties(
          circleRadius: ['case', ['get', 'selected'], 10, 6],
          circleColor: primary,
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: ['case', ['get', 'selected'], 3, 2],
        ),
        minzoom: kMinStopsZoom);
    // Stop names once zoomed in enough.
    await m.addSymbolLayer('nearby', 'nearby-label',
        SymbolLayerProperties(
          textField: ['get', 'name'],
          textFont: ['Noto Sans Regular'],
          textSize: 12,
          textColor: labelColor,
          textHaloColor: haloColor,
          textHaloWidth: 1.5,
          textAnchor: 'top',
          textOffset: [0, 0.9],
          textOptional: true,
        ),
        minzoom: kStopNamesZoom);
    m.onFeatureTapped.add((_, _, id, layerId, _) {
      if (layerId == 'area-buses-circle' || layerId == 'area-buses-label') {
        _openBus(id);
        return;
      }
      if (layerId != 'nearby-circle' && layerId != 'nearby-label') return;
      final stop = stopById[id];
      if (stop != null) _filterTo(stop);
    });
    await m.addLineLayer('route', 'route-casing',
        const LineLayerProperties(lineColor: '#FFFFFF', lineWidth: 10, lineCap: 'round', lineJoin: 'round'),
        filter: ['==', ['get', 'walk'], false], enableInteraction: false);
    await m.addLineLayer('route', 'route-line',
        const LineLayerProperties(lineColor: ['get', 'color'], lineWidth: 6, lineCap: 'round', lineJoin: 'round'),
        filter: ['==', ['get', 'walk'], false], enableInteraction: false);
    await m.addLineLayer('route', 'route-walk',
        const LineLayerProperties(lineColor: kWalkColor, lineWidth: 4, lineDasharray: [0.5, 2], lineCap: 'round'),
        filter: ['==', ['get', 'walk'], true], enableInteraction: false);
    // Where a live vehicle still has to travel before reaching your stop:
    // dotted, in the leg's color, under the route itself.
    await m.addLineLayer('approach', 'approach-line',
        const LineLayerProperties(
            lineColor: ['get', 'color'], lineWidth: 4, lineOpacity: 0.85, lineDasharray: [0.1, 2], lineCap: 'round'),
        belowLayerId: 'route-casing', enableInteraction: false);
    // Line view: the whole route and its stops (names when zoomed in).
    await m.addLineLayer('line', 'line-path',
        const LineLayerProperties(lineColor: ['get', 'color'], lineWidth: 5, lineCap: 'round', lineJoin: 'round'),
        belowLayerId: 'approach-line', enableInteraction: false);
    await m.addCircleLayer('line-stops', 'line-stops-circle',
        const CircleLayerProperties(
            circleRadius: 4, circleColor: '#FFFFFF', circleStrokeColor: ['get', 'color'], circleStrokeWidth: 2.5),
        enableInteraction: false);
    await m.addSymbolLayer('line-stops', 'line-stops-label',
        SymbolLayerProperties(
          textField: ['get', 'name'],
          textFont: ['Noto Sans Regular'],
          textSize: 11,
          textColor: labelColor,
          textHaloColor: haloColor,
          textHaloWidth: 1.5,
          textAnchor: 'left',
          textOffset: [0.8, 0],
          textOptional: true,
        ),
        minzoom: 15,
        enableInteraction: false);
    await m.addCircleLayer('stops', 'stops-circle',
        const CircleLayerProperties(
            circleRadius: 6, circleColor: '#FFFFFF', circleStrokeColor: ['get', 'color'], circleStrokeWidth: 3),
        enableInteraction: false);
    await m.addCircleLayer('endpoints', 'endpoints-circle',
        const CircleLayerProperties(
            circleRadius: 9, circleColor: ['get', 'color'], circleStrokeColor: '#FFFFFF', circleStrokeWidth: 3),
        enableInteraction: false);
    // Browsing: every bus around, smaller than a route's or line's own.
    await m.addCircleLayer('area-buses', 'area-buses-circle',
        const CircleLayerProperties(
            circleRadius: 11, circleColor: ['get', 'color'], circleStrokeColor: '#FFFFFF', circleStrokeWidth: 2),
        minzoom: AreaBuses.minZoom);
    await m.addSymbolLayer('area-buses', 'area-buses-label',
        const SymbolLayerProperties(
          textField: ['get', 'line'],
          textFont: ['Noto Sans Bold'],
          textSize: 9,
          textColor: '#FFFFFF',
          textAllowOverlap: true,
          textIgnorePlacement: true,
        ),
        minzoom: AreaBuses.minZoom);
    await m.addCircleLayer('buses', 'buses-circle',
        const CircleLayerProperties(
            circleRadius: 15, circleColor: ['get', 'color'], circleStrokeColor: '#FFFFFF', circleStrokeWidth: 3),
        enableInteraction: false);
    await m.addSymbolLayer('buses', 'buses-label',
        const SymbolLayerProperties(
          textField: ['get', 'line'],
          textFont: ['Noto Sans Bold'],
          textSize: 11,
          textColor: '#FFFFFF',
          textAllowOverlap: true,
          textIgnorePlacement: true,
        ),
        enableInteraction: false);
    styleReady = true;
    await m.updateContentInsets(_mapInsets());
    _drawNearbyStops();
    _drawEndpoints();
    _drawSelected();
    _refreshArea();
  }

  static String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  Map<String, dynamic> _point(LatLng p, Map<String, dynamic> props) => {
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [p.longitude, p.latitude]},
        'properties': props,
      };

  Map<String, dynamic> _collection(List<Map<String, dynamic>> f) => {'type': 'FeatureCollection', 'features': f};

  Future<void> _drawNearbyStops() async {
    if (!styleReady) return;
    await map!.setGeoJsonSource(
        'nearby',
        _collection([
          if (to == null && line == null)
            for (final s in nearbyStops)
              {
                ..._point(s.position, {'id': s.id, 'name': titleCase(s.name), 'selected': s.id == filterStop?.id}),
                'id': s.id,
              },
        ]));
  }

  Future<void> _drawEndpoints() async {
    if (!styleReady) return;
    await map!.setGeoJsonSource(
        'endpoints',
        _collection([
          if (to != null && !from.isMyLocation) _point(from.position, {'color': '#43A047'}),
          if (to != null) _point(to!.position, {'color': '#E53935'}),
        ]));
  }

  Map<String, String> _legColors(Itinerary it) {
    final colors = <String, String>{};
    var i = 0;
    for (final l in it.transitLegs) {
      colors[l.tripId ?? 'leg$i'] = kLegPalette[i % kLegPalette.length];
      i++;
    }
    return colors;
  }

  String _colorHexFor(Itinerary it, Leg leg) {
    if (!leg.transit) return kWalkColor;
    final idx = it.transitLegs.toList().indexOf(leg);
    return kLegPalette[idx % kLegPalette.length];
  }

  Color _colorFor(Itinerary it, Leg leg) => hexColor(_colorHexFor(it, leg));

  Future<void> _drawSelected({bool fit = true}) async {
    if (!styleReady) return;
    final it = selected;
    if (it == null) {
      await map!.setGeoJsonSource('route', _collection([]));
      await map!.setGeoJsonSource('stops', _collection([]));
      return;
    }
    await map!.setGeoJsonSource(
        'route',
        _collection([
          for (final l in it.legs)
            {
              'type': 'Feature',
              'geometry': {
                'type': 'LineString',
                'coordinates': [for (final p in l.points) [p.longitude, p.latitude]],
              },
              'properties': {'walk': !l.transit, 'color': _colorHexFor(it, l)},
            },
        ]));
    await map!.setGeoJsonSource(
        'stops',
        _collection([
          for (final l in it.transitLegs) ...[
            _point(l.from, {'color': _colorHexFor(it, l)}),
            _point(l.to, {'color': _colorHexFor(it, l)}),
          ],
        ]));
    if (fit) _fitTo([for (final l in it.legs) ...l.points]);
  }

  /// Map area hidden by overlays. The bottom is the sheet's resting height, so
  /// every camera move (fit, center on a leg, recenter) targets the part of the
  /// map you can actually see.
  EdgeInsets _mapInsets() {
    final mq = MediaQuery.of(context);
    // When the sheet covers (almost) everything, keep framing for the
    // half-height sheet: the map is about to be revealed at that size anyway.
    final h = sheet.extent > 0 ? sheet.extent : mq.size.height * 0.5;
    final bottom = math.min(h, mq.size.height * 0.62);
    return EdgeInsets.only(top: mq.padding.top + 64, bottom: bottom);
  }

  /// Whatever the current screen shows on the map.
  List<LatLng> _visibleContent() {
    final it = selected;
    if (it != null) return [for (final l in it.legs) ...l.points];
    if (line?.trip case final t?) return t.points;
    if (to != null) return [from.position, to!.position];
    // Browsing stops: keep the camera where the user put it.
    return const [];
  }

  /// Called when the sheet comes to rest: update the map's insets and reframe.
  Future<void> _onSheetSettled() async {
    final m = map;
    if (m == null || !styleReady) return;
    if (sheetValue == M3EBottomSheetValue.expanded || sheetValue == M3EBottomSheetValue.fullScreen) return;
    // Glide to the new visible area instead of jumping (the inset change
    // itself moves the map's centre)...
    await m.updateContentInsets(_mapInsets(), true);
    final pts = _visibleContent();
    if (pts.isEmpty) return;
    // ...then reframe once that glide is done: starting a camera animation
    // right away would cancel it and bring the jump back.
    await Future<void>.delayed(const Duration(milliseconds: 320));
    if (!mounted) return;
    if (pts.length > 1) {
      _fitTo(pts);
    } else if (pts.length == 1) {
      m.animateCamera(CameraUpdate.newLatLng(pts.first), duration: const Duration(milliseconds: 450));
    }
  }

  void _fitTo(List<LatLng> pts) {
    if (map == null || pts.isEmpty) return;
    var s = pts.first.latitude, n = s, w = pts.first.longitude, e = w;
    for (final p in pts) {
      s = math.min(s, p.latitude);
      n = math.max(n, p.latitude);
      w = math.min(w, p.longitude);
      e = math.max(e, p.longitude);
    }
    // Sheet and status bar are already content insets; this is just breathing room.
    map!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(southwest: LatLng(s, w), northeast: LatLng(n, e)),
        left: 48,
        right: 48,
        top: 32,
        bottom: 32,
      ),
      duration: const Duration(milliseconds: 600),
    );
  }

  // ---------- actions ----------

  void _setDestination(Place p) {
    HapticFeedback.mediumImpact();
    // Routes need room: lift the sheet if it was lowered to just the search bar.
    if (sheetValue == M3EBottomSheetValue.preview) sheet.animateTo(M3EBottomSheetValue.collapsed);
    _deselect();
    setState(() => to = p);
    toSearch.text = p.name;
    _drawNearbyStops();
    _drawEndpoints();
    _fitTo([from.position, p.position]);
    _plan();
  }

  Future<void> _setOrigin(Place p) async {
    if (p.isMyLocation) {
      if (here == null) return;
      p = _myLocation(here!);
    }
    _deselect();
    setState(() => from = p);
    fromSearch.text = p.name;
    _drawEndpoints();
    if (to != null) _plan();
  }

  void _clearDestination() {
    _deselect();
    setState(() {
      to = null;
      routes = [];
      _routeItineraries = [];
      error = null;
    });
    _syncLegTopics(); // nothing left to follow
    toSearch.clear();
    _drawNearbyStops();
    _drawEndpoints();
    _refreshArea(silent: true);
  }

  void _select(Itinerary it) {
    HapticFeedback.selectionClick();
    // A maximized sheet would hide the trip: bring it down so map and legs share the screen.
    if (sheetValue == M3EBottomSheetValue.expanded || sheetValue == M3EBottomSheetValue.fullScreen) {
      sheet.animateTo(M3EBottomSheetValue.collapsed);
    }
    // Rebuild the swipeable trip from the planner's original, with the rides
    // the walk rules replaced still walked by default.
    final v = TripVariants(it.base ?? it, walks: walkCache, walkSlots: it.walkSlots, choices: it.rideChoices);
    setState(() {
      variants = v;
      selected = v.current;
    });
    _syncLegTopics();
    _loadTripPaths(v.current);
    _drawSelected();
    _fetchTripWalks(v, all: true);
  }

  /// Fetches walking routes the trip shows estimated, and (with [all]) every
  /// leg's walk option for the swipe; then recomposes with real routes.
  Future<void> _fetchTripWalks(TripVariants v, {bool all = false}) async {
    final cache = walkCache;
    if (cache == null) return;
    await cache.fetch([
      ...v.missingWalks,
      if (all)
        for (var s = 0; s < v.slotCount; s++)
          if (v.walkIndex(s) != null) v.slotSpan(s),
    ], max: 8);
    if (!mounted || variants != v) return;
    v.refresh();
    // The real walk turned out too long to make a connection: back to rides.
    if (!v.feasible) v.restore(v.defaults);
    setState(() => selected = v.current);
    _syncLegTopics();
    _drawSelected(fit: false);
  }

  /// User swiped a leg to another ride: recompose the trip, keep the camera.
  void _swapRide(int slot, int variant) {
    final v = variants;
    if (v == null) return;
    final kept = v.choose(slot, variant);
    setState(() => selected = v.current);
    _syncLegTopics();
    _loadTripPaths(v.current);
    _drawSelected(fit: false);
    // A new walk (e.g. two walked legs merged) may need its street route.
    if (v.missingWalks.isNotEmpty) _fetchTripWalks(v);
    if (!kept) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(context.l10n.connectionResetSnack)));
    }
  }

  void _deselect() {
    if (selected == null) return;
    setState(() {
      selected = null;
      variants = null;
    });
    tracker.clear();
    _syncLegTopics(); // back to following the whole list
    tripPaths.clear();
    _drawApproach();
    _drawSelected();
  }

  void _recenter() {
    final p = here;
    if (p != null) map?.animateCamera(CameraUpdate.newLatLngZoom(p, 15.5));
  }

  // ---------- search ----------

  /// A search result or favourite: icon by kind, timetable button for stops,
  /// star to (un)favourite; tap sets it as origin / destination.
  Widget _placeTile(M3ESearchController c, Place p, {required bool isFrom}) {
    final cs = Theme.of(context).colorScheme;
    final isStop = p.kind == PlaceKind.stop;
    return ListTile(
      leading: isStop
          ? Icon(Icons.directions_bus_filled_rounded, color: cs.primary)
          : Icon(p.kind == PlaceKind.address ? Icons.home_outlined : Icons.place_outlined, color: cs.onSurfaceVariant),
      title: Text(p.name),
      subtitle: Text(
        [
          if (isStop && p.stopId != null) stopCodeFromId(p.stopId!),
          placeKindLabel(context.l10n, p.kind),
          ?p.subtitle,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (isStop && p.stopId != null)
          M3EIconButton(
            icon: const Icon(Icons.departure_board_rounded),
            tooltip: context.l10n.departuresFromThisStop,
            variant: M3EIconButtonVariant.tonal,
            onPressed: () {
              c.closeView(isFrom ? from.name : (to?.name ?? ''));
              _openStopTimetable(p);
            },
          ),
        ListenableBuilder(
          listenable: favorites,
          builder: (context, _) {
            final fav = favorites.isFavorite(p);
            return M3EIconButton(
              icon: Icon(fav ? Icons.star_rounded : Icons.star_outline_rounded, color: fav ? cs.primary : null),
              tooltip: fav ? context.l10n.removeFavourite : context.l10n.addFavourite,
              variant: M3EIconButtonVariant.standard,
              onPressed: () {
                HapticFeedback.selectionClick();
                favorites.toggle(p);
              },
            );
          },
        ),
      ]),
      onTap: () {
        c.closeView(p.name);
        isFrom ? _setOrigin(p) : _setDestination(p);
      },
    );
  }

  /// The geocoder returns one result per stop *name*; the pole across the
  /// road (other direction) has the same name and is left out. For the first
  /// few bus/tram stop results, look up same-name stops within ~150 m (one
  /// small area request each, in parallel) and list each right after it.
  Future<List<Place>> _withTwinStops(List<Place> results) async {
    final candidates = results.where((p) => p.kind == PlaceKind.stop && !p.station && p.stopId != null).take(5).toList();
    final twins = <String, List<Place>>{};
    await Future.wait(candidates.map((p) async {
      try {
        const dLat = 0.0014, dLon = 0.0019; // ~150 m
        final near = await backend.stops.stopsInArea(
          LatLngBounds(
            southwest: LatLng(p.position.latitude - dLat, p.position.longitude - dLon),
            northeast: LatLng(p.position.latitude + dLat, p.position.longitude + dLon),
          ),
          from: p.position,
        );
        twins[p.stopId!] = [
          for (final s in near)
            if (s.id != p.stopId && s.name.toUpperCase() == p.name.toUpperCase())
              Place(name: s.name, subtitle: p.subtitle, position: s.position, kind: PlaceKind.stop, stopId: s.id),
        ];
      } catch (_) {
        // no twins: the single result stays
      }
    }));
    return [
      for (final p in results) ...[p, ...?twins[p.stopId]],
    ];
  }

  Future<Iterable<Widget>> _suggestions(M3ESearchController c, {required bool isFrom}) async {
    final q = c.text.trim();
    final cs = Theme.of(context).colorScheme;
    final l = context.l10n; // also after the awaits below
    final items = <Widget>[
      if (isFrom && here != null)
        ListTile(
          leading: Icon(Icons.my_location_rounded, color: cs.primary),
          title: Text(context.l10n.myLocation),
          onTap: () {
            c.closeView(context.l10n.myLocation);
            _setOrigin(_myLocation(here ?? _fallback.position));
          },
        ),
    ];
    // Nothing typed yet (empty, or still the field's current value):
    // favourites, as Stops and Destinations.
    if (q.isEmpty || q == context.l10n.myLocation || q == to?.name || (isFrom && q == from.name)) {
      for (final (title, list) in [
        (context.l10n.favouriteStops, favorites.stops),
        (context.l10n.favouriteDestinations, favorites.destinations),
      ]) {
        if (list.isEmpty) continue;
        items.add(_SuggestionHeader(title));
        items.addAll(list.map((p) => _placeTile(c, p, isFrom: isFrom)));
      }
      return items;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (c.text.trim() != q) return items; // a newer query is on its way
    // A line with buses running right now ("492", "n6"): open the line
    // view. Asked to Tramite, exact number, for each source it covers.
    if (!isFrom && q.length <= 6 && !q.contains(' ') && backend.trips != null && tramite.prefixes.isNotEmpty) {
      final found = await Future.wait([
        for (final p in tramite.prefixes)
          tramite
              .lineVehicles(TramiteClient.lineId(p, q))
              .then((buses) => (id: TramiteClient.lineId(p, q), buses: buses))
              .catchError((Object _) => (id: '', buses: <({Vehicle vehicle, String? color})>[])),
      ]);
      if (c.text.trim() != q) return items;
      for (final (:id, :buses) in found) {
        if (buses.isEmpty) continue;
        final name = buses.first.vehicle.routeShortName ?? q;
        final color = buses.first.color;
        items.add(ListTile(
          leading: LinePill(line: name, mode: 'BUS', color: color == null ? cs.primary : hexColor(color)),
          title: Text(l.lineName(name)),
          subtitle: Text(l.busesLive(buses.length)),
          onTap: () {
            c.closeView('');
            _openLine(name: name, mode: 'BUS', lineId: id);
          },
        ));
      }
    }
    if (q.length < 2) return items;
    try {
      final reference = here ?? map?.cameraPosition?.target ?? _fallback.position;
      final ranked = rankByProximity(await backend.places.search(q, near: reference), reference);
      // A typed stop number means that exact pole: no twins then.
      final results = RegExp(r'^\d+$').hasMatch(q) ? ranked : await _withTwinStops(ranked);
      if (c.text.trim() != q) return items;
      // Stops are distinct by stop id (each pole is one direction); other
      // results drop exact duplicates (same name and label).
      final seen = <String>{};
      final unique = results.where((p) => seen.add(p.stopId ?? '${p.name}|${p.subtitle}'));
      items.addAll(unique.map((p) => _placeTile(
            c,
            Place(
              name: titleCase(p.name),
              subtitle: p.subtitle,
              position: p.position,
              kind: p.kind,
              stopId: p.stopId,
              station: p.station,
            ),
            isFrom: isFrom,
          )));
    } catch (e) {
      items.add(ListTile(title: Text(l.searchFailed('$e'))));
    }
    return items;
  }

  Widget _searchArea() {
    final expanded = sheetValue == M3EBottomSheetValue.expanded || sheetValue == M3EBottomSheetValue.fullScreen;
    return RoutePicker(
      expanded: expanded,
      fromSearch: fromSearch,
      toSearch: toSearch,
      fromLabel: from.name,
      toLabel: to?.name,
      fromIsMyLocation: from.isMyLocation,
      fromSuggestions: (_, c) => _suggestions(c, isFrom: true),
      toSuggestions: (_, c) => _suggestions(c, isFrom: false),
      onClear: _clearDestination,
      onSwap: _swap,
    );
  }

  void _swap() {
    final dest = to;
    if (dest == null) return;
    final origin = from;
    _deselect();
    setState(() {
      from = dest;
      to = origin;
    });
    fromSearch.text = dest.name;
    toSearch.text = origin.name;
    _drawEndpoints();
    _plan();
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: selected == null && to == null && line == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (line != null) return _closeLine();
        selected != null ? _deselect() : _clearDestination();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
            .copyWith(statusBarColor: Colors.transparent, systemNavigationBarColor: Colors.transparent),
        child: Scaffold(
          backgroundColor: cs.surface,
          body: Stack(children: [
            MapLibreMap(
              key: ValueKey(isDark),
              styleString: isDark ? kMapStyleDark : kMapStyleLight,
              initialCameraPosition: CameraPosition(target: here ?? _fallback.position, zoom: 15.5),
              onMapCreated: (c) {
                map = c;
                styleReady = false;
              },
              onStyleLoadedCallback: _onStyleLoaded,
              onCameraIdle: _onCameraIdle,
              // Keeps controller.cameraPosition (centre, zoom) current; the
              // area logic reads it after every move.
              trackCameraPosition: true,
              onMapLongClick: (_, ll) => _setDestination(Place(name: context.l10n.droppedPin, position: ll)),
              myLocationEnabled: locationGranted,
              compassEnabled: false,
              attributionEnabled: false, // replaced by MapCredit
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 12, 0),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const MapCredit(),
                  const Spacer(),
                  if (here != null)
                    M3EIconButton(
                      icon: const Icon(Icons.my_location_rounded),
                      tooltip: context.l10n.myLocation,
                      variant: M3EIconButtonVariant.tonal,
                      size: M3EIconButtonSize.md,
                      onPressed: _recenter,
                    ),
                ]),
              ),
            ),
            Positioned.fill(
              child: M3EBottomSheet.standard(
                controller: sheet,
                // Nothing to reveal when only the search bar is shown.
                enableDrag: !_onlySearchBar,
                previewHeight: kSheetPeek + MediaQuery.paddingOf(context).bottom,
                initialValue: M3EBottomSheetValue.collapsed,
                onValueChanged: (v) {
                  setState(() => sheetValue = v);
                  _onSheetSettled();
                },
                child: CustomScrollView(slivers: [
                  if (selected == null && line == null) SliverToBoxAdapter(child: _searchArea()),
                  ..._content(),
                  SliverToBoxAdapter(child: SizedBox(height: 24 + MediaQuery.paddingOf(context).bottom)),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /// A route goes under Live when its first ride is backed by a real bus.
  bool _routeLive(RouteGroup g) =>
      g.isLive || g.best.transitLegs.take(1).any((l) => _certainty(l.realtime, l.tripId) != Certainty.scheduled);

  /// Like [_certainty], also from the buses on the map (the line view's,
  /// whose trips aren't rides of a journey): live with its bus seen is on
  /// its way, or waiting while the bus hasn't started.
  Certainty _trackedCertainty(bool realtime, String? tripId) {
    final bus = tripId == null ? null : tracker.buses[tripId]?.vehicle;
    if (realtime && bus != null && _legRows[tripId] == null) return bus.started ? Certainty.moving : Certainty.waiting;
    return _certainty(realtime, tripId);
  }

  /// Zoomed out on the stops view: the sheet holds just the search bar.
  bool get _onlySearchBar => selected == null && to == null && line == null && zoomedOut;

  List<Widget> _content() {
    if (line case final l?) {
      return lineSlivers(
        context,
        l,
        color: Theme.of(context).colorScheme.primary,
        liveBuses: _lineTopics.topics.isEmpty ? null : tracker.buses.length,
        certainty: _trackedCertainty(l.trip?.realtime ?? false, MotisClient.rawTripId(l.tripId)),
        onBack: _closeLine,
        onSwitchDirection: _otherDirection() == null ? null : () => _loadLineTrip(_otherDirection()!),
        onStopTap: (stop) => map?.animateCamera(CameraUpdate.newLatLngZoom(stop.position, 16.5)),
      );
    }
    if (selected != null) return _tripSlivers(selected!);
    if (to != null) return _routeSlivers();
    if (zoomedOut) return const []; // only the search bar
    return _nearbySlivers();
  }

  Widget _errorBox(String e) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(e, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      );

  List<Widget> _nearbySlivers() {
    return [
      SliverToBoxAdapter(
        child: SheetSectionHeader(
          filterStop != null
              ? context.l10n.departuresFrom
              : areaMode
                  ? context.l10n.departuresInArea
                  : here == null
                      ? context.l10n.departuresNearTermini
                      : context.l10n.departuresNearYou,
          trailing: nearbyLoading && nearby.isNotEmpty
              ? const SizedBox(width: 24, height: 24, child: M3ELoadingIndicator(size: 24))
              : null,
        ),
      ),
      if (filterStop case final stop?)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
            child: Row(children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: M3EChip(
                    label: '${titleCase(stop.name)} · ${stop.code}',
                    type: M3EChipType.input,
                    selected: true,
                    leading: const Icon(Icons.place_rounded),
                    onPressed: () => map?.animateCamera(CameraUpdate.newLatLngZoom(stop.position, 17)),
                    onDeleted: _clearFilter,
                  ),
                ),
              ),
              // Favourite this exact stop (same store as the stars in search).
              ListenableBuilder(
                listenable: favorites,
                builder: (context, _) {
                  final place = Place(
                    name: titleCase(stop.name),
                    position: stop.position,
                    kind: PlaceKind.stop,
                    stopId: stop.id,
                  );
                  final fav = favorites.isFavorite(place);
                  return M3EIconButton(
                    icon: Icon(
                      fav ? Icons.star_rounded : Icons.star_outline_rounded,
                      color: fav ? Theme.of(context).colorScheme.primary : null,
                    ),
                    tooltip: fav ? context.l10n.removeFavourite : context.l10n.addFavourite,
                    variant: M3EIconButtonVariant.standard,
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      favorites.toggle(place);
                    },
                  );
                },
              ),
            ]),
          ),
        ),
      if (error != null) _errorBox(error!),
      if (nearbyLoading && nearby.isEmpty)
        SliverToBoxAdapter(child: SheetLoading(label: filterStop != null ? context.l10n.loadingDepartures : context.l10n.findingStops))
      else if (nearby.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(filterStop != null
                ? context.l10n.noDeparturesFromStop
                : nearbyStops.isEmpty
                    ? context.l10n.noStopsInArea
                    : context.l10n.noDeparturesHere),
          ),
        )
      else ...[
        // Live first (backed by a real bus: on its way, parked, or coming
        // back around), then timetable-only; each keeps the soonest-first
        // order.
        for (final (live, list) in [
          (true, nearby.where((r) => _depCertainty(r.next.first) != Certainty.scheduled).toList()),
          (false, nearby.where((r) => _depCertainty(r.next.first) == Certainty.scheduled).toList()),
        ])
          if (list.isNotEmpty) ...[
            SliverToBoxAdapter(child: RouteSectionLabel(live: live, count: list.length)),
            M3EList.sliver(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: list.length,
              itemBuilder: (_, i) =>
                  NearbyDepartureRow(
                    row: list[i],
                    certainty: _depCertainty(list[i].next.first),
                    showStop: filterStop == null,
                  ),
              onTap: (i) {
                final d = list[i].next.first;
                _openLine(
                  name: list[i].line,
                  mode: list[i].mode,
                  tripId: d.backendTripId,
                  hint: d.stopId == null ? null : (stopId: d.stopId!, at: d.time),
                );
              },
            ),
          ],
      ],
    ];
  }

  List<Widget> _routeSlivers() {
    return [
      SliverToBoxAdapter(
        child: SheetSectionHeader(
          context.l10n.routesByArrival(routes.length),
          trailing: planning && routes.isNotEmpty
              ? const SizedBox(width: 24, height: 24, child: M3ELoadingIndicator(size: 24))
              : M3EIconButton(
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: context.l10n.refresh,
                  variant: M3EIconButtonVariant.standard,
                  onPressed: planning ? null : () => _plan(),
                ),
        ),
      ),
      if (error != null) _errorBox(error!),
      if (planning && routes.isEmpty)
        SliverToBoxAdapter(child: SheetLoading(label: context.l10n.comparingRoutes))
      else ...[
        // Walking suggested ("Faster on foot") first, then live, then
        // timetable-only, then walking when it isn't competitive; each list
        // keeps the arrival order.
        for (final (label, list) in [
          (null, routes.where((g) => g.tags.contains(RouteTag.onFoot)).toList()),
          ('live', routes.where((g) => !g.isWalk && _routeLive(g)).toList()),
          ('scheduled', routes.where((g) => !g.isWalk && !_routeLive(g)).toList()),
          ('walk', routes.where((g) => g.isWalk && !g.tags.contains(RouteTag.onFoot)).toList()),
        ])
          if (list.isNotEmpty) ...[
            if (label != null)
              SliverToBoxAdapter(
                child: RouteSectionLabel(live: label == 'live', onFoot: label == 'walk', count: list.length),
              )
            else
              const SliverToBoxAdapter(child: SizedBox(height: 4)),
            M3EList.sliver(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: list.length,
              itemBuilder: (_, i) => RouteGroupRow(
                group: list[i],
                colorFor: _colorFor,
                certaintyFor: (l) => _certainty(l.realtime, l.tripId),
              ),
              onTap: (i) => _select(list[i].best),
            ),
          ],
      ],
    ];
  }

  /// The line under a selected journey's header: how many of its rides
  /// have their bus on the map.
  String _tripStatus(Itinerary it, int? feedAge) {
    final l = context.l10n;
    if (it.transitLegs.isEmpty) return l.tripWalkingOnly;
    final covered = it.transitLegs.where((leg) => tramite.covers(leg.backendTripId)).length;
    if (covered == 0) return l.tripNoLivePositions;
    if (!live.connected.value) return l.tripLivePositionsUnavailable;
    return [l.tripTracking(tracker.buses.length, covered), if (feedAge != null) l.tripPositionsAge(feedAge)].join(' · ');
  }

  List<Widget> _tripSlivers(Itinerary it) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final feedAge = tracker.lastFeed == null ? null : DateTime.now().difference(tracker.lastFeed!).inSeconds;
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 24, 8),
          child: Row(children: [
            M3EIconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              tooltip: context.l10n.backToRoutes,
              variant: M3EIconButtonVariant.standard,
              onPressed: _deselect,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Semantics(
                  label: context.l10n.fromToSemantics(hm(it.start), hm(it.end)),
                  excludeSemantics: true,
                  child: Row(children: [
                    Text(hm(it.start), style: emphasized(context).headlineSmall.copyWith(color: cs.onSurface)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(Icons.arrow_forward_rounded, size: 22, color: cs.onSurfaceVariant),
                    ),
                    Text(hm(it.end), style: emphasized(context).headlineSmall.copyWith(color: cs.onSurface)),
                  ]),
                ),
                Text(
                  context.l10n.tripSummary(it.duration.inMinutes, it.transfers, to?.name ?? ''),
                  overflow: TextOverflow.ellipsis,
                  style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              ]),
            ),
          ]),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Text(
            _tripStatus(it, feedAge),
            style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ),
      M3EList.sliver(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: it.legs.length,
        itemBuilder: (_, i) {
          final l = it.legs[i];
          // Minutes until this vehicle reaches its boarding stop. (The gap
          // between arriving on foot and boarding is ~0 by construction: the
          // planner times walks to end when the bus comes.)
          final wait = l.transit ? minutesUntil(l.start) : null;
          final row = LegRow(
            leg: l,
            color: _colorFor(it, l),
            bus: tracker.buses[l.tripId],
            waitMinutes: wait,
            certainty: _trackedCertainty(l.realtime, l.tripId),
          );
          final v = variants;
          final slot = v?.slotOfLeg(i);
          if (v == null || slot == null || v.variantCount(slot) < 2) return row;
          return SwipeSlot(
            index: v.choiceOf(slot),
            count: v.variantCount(slot),
            labels: [
              for (var k = 0; k < v.variantCount(slot); k++)
                v.isWalk(slot, k)
                    ? context.l10n.swipeWalk(v.walkDurationOf(slot).inMinutes)
                    : '${v.rideOf(slot, k).routeShortName ?? v.rideOf(slot, k).mode} ${hm(v.rideOf(slot, k).start)}',
            ],
            onChanged: (k) => _swapRide(slot, k),
            child: row,
          );
        },
        onTap: (i) {
          final l = it.legs[i];
          final bus = tracker.buses[l.tripId];
          map?.animateCamera(CameraUpdate.newLatLngZoom(bus?.drawn ?? l.from, 16));
        },
      ),
    ];
  }
}

/// Section title in the search view ("Stops", "Destinations").
class _SuggestionHeader extends StatelessWidget {
  const _SuggestionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
        child: Text(title, style: emphasized(context).labelLarge.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}
