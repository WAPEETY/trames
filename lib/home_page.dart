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
import 'backend/motis.dart' show MotisClient;
import 'backend/returning.dart';
import 'backend/route_search.dart';
import 'backend/trip_variants.dart';
import 'attribution.dart';
import 'favorites.dart';
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
  final fromSearch = M3ESearchController()..text = 'My location';
  MapLibreMapController? map;
  bool styleReady = false;
  bool locationGranted = false;
  M3EBottomSheetValue sheetValue = M3EBottomSheetValue.collapsed;

  LatLng? here;
  Place from = Place(name: 'My location', position: kCities.first.fallbackCenter.position, isMyLocation: true);
  Place? to;

  // Departures for the visible map area (idle state).
  List<BoardRow> nearby = [];

  /// Live buses by raw trip id, from the GPS feed, refreshed with the
  /// departures and the routes. Null with no GPS feed here (or it failed):
  /// then any live time counts as a bus on its way.
  /// Keyed by trip id and by run key (see indexVehicles).
  Map<String, Vehicle>? liveVehicles;

  Future<Map<String, Vehicle>?> _fetchVehicles() async {
    final f = backend.vehicles;
    if (f == null) return null;
    try {
      final snap = await f.vehicles();
      return indexVehicles(snap.vehicles);
    } catch (_) {
      return null;
    }
  }

  /// Timetable-only departures a bus coming back from the other direction
  /// could run (see ReturnEstimator): for the stop board and for the routes.
  Map<String, ReturnEstimate> boardReturns = {};
  Map<String, ReturnEstimate> routeReturns = {};

  /// Board rows as fetched (before estimates), to rebuild [nearby].
  List<BoardRow> _boardRows = [];

  /// How sure a time is: bus on the way, not departed yet, a bus coming back
  /// around, or timetable only.
  Certainty _certainty(bool realtime, String? tripId, [String? runKey]) => certaintyOf(
        realtime: realtime,
        tripId: tripId,
        runKey: runKey,
        vehicles: liveVehicles,
        returns: to != null ? routeReturns : boardReturns,
      );

  Certainty _depCertainty(Departure d) => _certainty(d.realtime, d.tripId, d.runKey);

  /// Looks for buses coming back to run timetable-only departures: one
  /// query per line and terminus, soonest departures first. Only for lines
  /// all on the timetable here: one live departure (yellow or green) and
  /// the line is left alone. Empty where the city has no GPS feed.
  Future<Map<String, ReturnEstimate>> _estimateReturns(
      Iterable<(String line, Departure departure)> departures, Map<String, Vehicle>? vehicles) async {
    final source = backend.returns;
    if (source == null || vehicles == null) return const {};
    String key(String line, Departure d) => '${line.toLowerCase()}|${d.origin?.stopId}';
    final live = {for (final (line, d) in departures) if (d.realtime) key(line, d)};
    final soonest = departures
        .where((e) => !e.$2.realtime && e.$2.origin != null && !live.contains(key(e.$1, e.$2)))
        .toList()
      ..sort((a, b) => a.$2.time.compareTo(b.$2.time));
    return ReturnEstimator(source).estimate([for (final (line, d) in soonest) ReturnQuery(line, d.origin!)], vehicles);
  }

  /// [nearby] from the fetched rows and the estimates: purple times moved to
  /// the estimate; one stop lists every bus, nearby one row per line +
  /// direction (from whichever stop has it soonest).
  List<BoardRow> _buildNearby() {
    final rows = applyReturnEstimates(_boardRows, boardReturns);
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
  VehicleSnapshot? _vehCache;
  DateTime? _vehCacheAt;
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

  late final LiveBusTracker tracker = LiveBusTracker(
    feed: backend.vehicles,
    onFrame: (g) async {
      if (map != null && styleReady) await map!.setGeoJsonSource('buses', g);
    },
    onSnapshot: () {
      if (!mounted) return;
      setState(() {});
      _drawApproach();
    },
  );

  @override
  void initState() {
    super.initState();
    _initLocation();
    // Nearby boards every 30 s while idle; routes every 60 s while listing.
    refreshTimer = Timer.periodic(const Duration(seconds: 30), (t) {
      if (line != null) {
        // the tracker refreshes the line's buses on its own
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
    tracker.stop();
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
          from = Place(name: 'My location', position: here!, isMyLocation: true);
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
    if (to != null || line != null) return; // the area list isn't shown
    idleDebounce?.cancel();
    idleDebounce = Timer(kAreaIdleDelay, _refreshArea);
  }

  /// Loads stops in the visible map area (pins) and departures from the
  /// nearest of them, or from [filterStop] only when one is selected.
  Future<void> _refreshArea({bool silent = false}) async {
    final m = map;
    if (m == null || !styleReady || to != null || line != null) return;
    final seq = ++_areaSeq;
    final camera = m.cameraPosition;
    final zoom = camera?.zoom ?? 15;

    if (zoom < kMinStopsZoom) {
      // Only the search bar is left: drop the sheet to its lowest height
      // (dragging is disabled while in this state, see build()).
      if (!zoomedOut) sheet.animateTo(M3EBottomSheetValue.preview);
      setState(() {
        zoomedOut = true;
        nearbyStops = [];
        nearby = [];
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
      // The live feed tells which buses already went by (see
      // dropPassedDepartures); without it, the boards as they are.
      final running = _fetchVehicles();
      final boards =
          await Future.wait(boardStops.map((s) => backend.stops.board(s).catchError((_) => <BoardRow>[])));
      final vehicles = await running;
      if (seq != _areaSeq || !mounted) return;
      final rows = dropPassedDepartures(boards.expand((b) => b).toList(), vehicles?.keys.toSet() ?? const {});
      setState(() {
        nearbyStops = pins;
        liveVehicles = vehicles;
        stopById
          ..clear()
          ..addEntries(pins.map((s) => MapEntry(s.id, s)));
        _boardRows = rows;
        // Keep the last estimates for trips still listed until the new ones
        // arrive (no flicker back to grey on every refresh).
        final listed = {for (final r in rows) for (final d in r.next) d.tripId};
        boardReturns = {for (final e in boardReturns.entries) if (listed.contains(e.key)) e.key: e.value};
        nearby = _buildNearby();
        error = null;
      });
      _drawNearbyStops();
      // Then buses coming back from the other direction (a few requests).
      final returns = await _estimateReturns([for (final r in rows) for (final d in r.next) (r.line, d)], vehicles);
      if (seq != _areaSeq || !mounted) return;
      setState(() {
        boardReturns = returns;
        nearby = _buildNearby();
      });
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
    setState(() {
      planning = true;
      error = null;
      if (!silent) routes = [];
    });
    try {
      // Several planner profiles merged and grouped by line sequence,
      // groups ordered by earliest arrival (see RouteSearch).
      final vehicles = _fetchVehicles();
      final list = await routeSearch.search(from.position, dest.position);
      final live = await vehicles;
      if (!mounted || to != dest) return;
      setState(() {
        _routeItineraries = [for (final g in list) ...g.options];
        liveVehicles = live;
        // Last estimates for trips still listed, until the new ones arrive
        // (no flicker back to the timetable on every refresh).
        final listed = {for (final it in _routeItineraries) for (final l in it.transitLegs) l.tripId};
        routeReturns = {for (final e in routeReturns.entries) if (listed.contains(e.key)) e.key: e.value};
        routes = _buildRoutes();
      });
      // Then buses coming back for timetable-only rides: red, or purple
      // with the rides re-planned around our estimate.
      final returns = await _estimateReturns([
        for (final g in list)
          for (final it in g.options)
            for (final l in it.transitLegs)
              (
                l.routeShortName ?? l.mode,
                Departure(time: l.start, realtime: l.realtime, tripId: l.tripId, origin: l.origin),
              ),
      ], live);
      if (!mounted || to != dest) return;
      setState(() {
        routeReturns = returns;
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

  /// All live vehicles, cached briefly (search typing, line directions).
  Future<VehicleSnapshot> _liveVehicles() async {
    final at = _vehCacheAt;
    if (_vehCache != null && at != null && DateTime.now().difference(at) < const Duration(seconds: 20)) {
      return _vehCache!;
    }
    final feed = backend.vehicles;
    if (feed == null) throw StateError('no live GPS feed here');
    final snap = await feed.vehicles();
    _vehCache = snap;
    _vehCacheAt = DateTime.now();
    return snap;
  }

  /// Opens the line view for [name]. [tripId] (a tapped departure) picks the
  /// direction to show; otherwise the first direction with a live bus.
  Future<void> _openLine({required String name, required String mode, String? tripId, VehicleSnapshot? snapshot}) async {
    final trips = backend.trips;
    if (trips == null) return;
    HapticFeedback.selectionClick();
    if (selected != null) _deselect();
    if (to != null) _clearDestination();
    final state = LineState(name, mode)..tripId = tripId;
    setState(() => line = state);
    if (sheetValue == M3EBottomSheetValue.preview) sheet.animateTo(M3EBottomSheetValue.collapsed);
    _drawNearbyStops();
    if (backend.vehicles != null) tracker.trackLine(name, _lineColor);

    // One trip id per direction, from the line's live buses.
    if (backend.vehicles != null) {
      try {
        final snap = snapshot ?? await _liveVehicles();
        for (final v in snap.vehicles) {
          if (v.routeShortName?.toLowerCase() != name.toLowerCase()) continue;
          final id = trips.tripIdForVehicle(v);
          if (id != null) state.directions.putIfAbsent(v.directionId ?? 0, () => id);
        }
      } catch (_) {}
    }
    if (line != state) return;
    final first = tripId ?? state.directions.values.firstOrNull;
    if (first == null) {
      setState(() => state.error = backend.vehicles == null
          ? 'Live buses aren\'t available in this area.'
          : 'No bus of line $name is running right now.');
      return;
    }
    await _loadLineTrip(first);
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
      final t = await trips.trip(id);
      if (line != state) return;
      setState(() => state.trip = t);
      _drawLine();
      _fitTo(t.points);
    } catch (e) {
      if (line == state) setState(() => state.error = 'Could not load the line: $e');
    }
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
    tracker.stop();
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
      _vehCache = null;
    });
    tracker.feed = backend.vehicles;
    if (backend.vehicles == null) tracker.stop();
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

  /// Run key -> trip id of each ride (see LiveBusTracker.track).
  Map<String, String> _legRuns(Itinerary it) => {
        for (final l in it.transitLegs)
          if (l.runKey != null && l.tripId != null) l.runKey!: l.tripId!,
      };

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
      p = Place(name: 'My location', position: here!, isMyLocation: true);
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
      error = null;
    });
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
    tracker.track(_legColors(v.current), runs: _legRuns(v.current));
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
    tracker.track(_legColors(v.current), runs: _legRuns(v.current));
    _drawSelected(fit: false);
  }

  /// User swiped a leg to another ride: recompose the trip, keep the camera.
  void _swapRide(int slot, int variant) {
    final v = variants;
    if (v == null) return;
    final kept = v.choose(slot, variant);
    setState(() => selected = v.current);
    tracker.track(_legColors(v.current), runs: _legRuns(v.current));
    _loadTripPaths(v.current);
    _drawSelected(fit: false);
    // A new walk (e.g. two walked legs merged) may need its street route.
    if (v.missingWalks.isNotEmpty) _fetchTripWalks(v);
    if (!kept) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Other changes reset: that connection would be missed')));
    }
  }

  void _deselect() {
    if (selected == null) return;
    setState(() {
      selected = null;
      variants = null;
    });
    tracker.stop();
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
        [if (isStop && p.stopId != null) stopCodeFromId(p.stopId!), ?p.subtitle].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (isStop && p.stopId != null)
          M3EIconButton(
            icon: const Icon(Icons.departure_board_rounded),
            tooltip: 'Departures from this stop',
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
              tooltip: fav ? 'Remove from favourites' : 'Add to favourites',
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
    final items = <Widget>[
      if (isFrom && here != null)
        ListTile(
          leading: Icon(Icons.my_location_rounded, color: cs.primary),
          title: const Text('My location'),
          onTap: () {
            c.closeView('My location');
            _setOrigin(Place(name: 'My location', position: here ?? _fallback.position, isMyLocation: true));
          },
        ),
    ];
    // Nothing typed yet (empty, or still the field's current value):
    // favourites, as Stops and Destinations.
    if (q.isEmpty || q == 'My location' || q == to?.name || (isFrom && q == from.name)) {
      for (final (title, list) in [('Stops', favorites.stops), ('Destinations', favorites.destinations)]) {
        if (list.isEmpty) continue;
        items.add(_SuggestionHeader(title));
        items.addAll(list.map((p) => _placeTile(c, p, isFrom: isFrom)));
      }
      return items;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (c.text.trim() != q) return items; // a newer query is on its way
    // Lines with buses running right now ("492", "n6"...): open the line view.
    if (!isFrom && q.length <= 6 && !q.contains(' ') && backend.trips != null && backend.vehicles != null) {
      try {
        final snap = await _liveVehicles();
        final counts = <String, int>{};
        for (final v in snap.vehicles) {
          final l = v.routeShortName;
          if (l != null && l.toLowerCase().startsWith(q.toLowerCase())) counts[l] = (counts[l] ?? 0) + 1;
        }
        final lines = counts.keys.toList()
          ..sort((a, b) {
            final exact = (b.toLowerCase() == q.toLowerCase() ? 1 : 0) - (a.toLowerCase() == q.toLowerCase() ? 1 : 0);
            return exact != 0 ? exact : a.length != b.length ? a.length - b.length : a.compareTo(b);
          });
        items.addAll(lines.take(4).map((l) => ListTile(
              leading: LinePill(line: l, mode: 'BUS', color: cs.primary),
              title: Text('Line $l'),
              subtitle: Text(counts[l] == 1 ? '1 bus live' : '${counts[l]} buses live'),
              onTap: () {
                c.closeView('');
                _openLine(name: l, mode: 'BUS', snapshot: snap);
              },
            )));
      } catch (_) {
        // no live data: just the place search below
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
      items.add(ListTile(title: Text('Search failed: $e')));
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
              onMapLongClick: (_, ll) => _setDestination(Place(name: 'Dropped pin', position: ll)),
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
                      tooltip: 'My location',
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
      g.isLive || g.best.transitLegs.take(1).any((l) => _certainty(l.realtime, l.tripId, l.runKey) != Certainty.scheduled);

  /// Like [_certainty], from the buses the tracker follows (trip and line
  /// views, polled live): a followed trip with no bus yet is waiting.
  Certainty _trackedCertainty(bool realtime, String? tripId, [String? runKey]) => certaintyOf(
        realtime: realtime,
        tripId: tripId,
        runKey: runKey,
        vehicles: backend.vehicles == null || tracker.lastError != null
            ? null
            : indexVehicles(tracker.buses.values.map((b) => b.vehicle)),
        returns: routeReturns,
      );

  /// Zoomed out on the stops view: the sheet holds just the search bar.
  bool get _onlySearchBar => selected == null && to == null && line == null && zoomedOut;

  List<Widget> _content() {
    if (line case final l?) {
      return lineSlivers(
        context,
        l,
        color: Theme.of(context).colorScheme.primary,
        liveBuses: backend.vehicles == null ? null : tracker.buses.length,
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
              ? 'Departures from'
              : areaMode
                  ? 'Departures in this area'
                  : here == null
                      ? 'Departures near Termini'
                      : 'Departures near you',
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
                    tooltip: fav ? 'Remove from favourites' : 'Add to favourites',
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
        SliverToBoxAdapter(child: SheetLoading(label: filterStop != null ? 'Loading departures' : 'Finding stops'))
      else if (nearby.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(filterStop != null
                ? 'No departures from this stop in the next hour.'
                : nearbyStops.isEmpty
                    ? 'No stops in this area.'
                    : 'No departures in the next hour here.'),
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
              onTap: (i) => _openLine(
                name: list[i].line,
                mode: list[i].mode,
                tripId: list[i].next.first.backendTripId,
              ),
            ),
          ],
      ],
    ];
  }

  List<Widget> _routeSlivers() {
    return [
      SliverToBoxAdapter(
        child: SheetSectionHeader(
          routes.length > 1 ? '${routes.length} routes · by arrival' : 'Routes · by arrival',
          trailing: planning && routes.isNotEmpty
              ? const SizedBox(width: 24, height: 24, child: M3ELoadingIndicator(size: 24))
              : M3EIconButton(
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: 'Refresh',
                  variant: M3EIconButtonVariant.standard,
                  onPressed: planning ? null : () => _plan(),
                ),
        ),
      ),
      if (error != null) _errorBox(error!),
      if (planning && routes.isEmpty)
        const SliverToBoxAdapter(child: SheetLoading(label: 'Comparing routes with live times'))
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
                certaintyFor: (l) => _certainty(l.realtime, l.tripId, l.runKey),
              ),
              onTap: (i) => _select(list[i].best),
            ),
          ],
      ],
    ];
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
              tooltip: 'Back to routes',
              variant: M3EIconButtonVariant.standard,
              onPressed: _deselect,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Semantics(
                  label: 'from ${hm(it.start)} to ${hm(it.end)}',
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
                  '${it.duration.inMinutes} min · ${it.transfers} transfer${it.transfers == 1 ? '' : 's'}'
                  ' · to ${to?.name ?? ''}',
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
            backend.vehicles == null
                ? 'No live bus positions in this area'
                : tracker.lastError != null
                ? 'Live positions unavailable'
                : it.transitLegs.isEmpty
                    ? 'Walking only'
                    : 'Tracking ${tracker.buses.length} of ${it.transitLegs.length} vehicles'
                        '${feedAge != null ? ' · feed ${feedAge}s old' : ''}',
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
            certainty: _trackedCertainty(l.realtime, l.tripId, l.runKey),
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
                    ? 'walk ${v.walkDurationOf(slot).inMinutes} min'
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
