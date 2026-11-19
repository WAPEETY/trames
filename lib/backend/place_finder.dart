import 'dart:math';

import 'package:maplibre_gl/maplibre_gl.dart';

import 'backend.dart';
import 'motis.dart';
import 'photon.dart';

/// Locates a search suggestion that came without a position
/// ([Place.needsLocating]).
abstract interface class PlaceLocator {
  Future<Place> locate(Place p);
}

/// The app's search: stops from MOTIS (they carry the stop ids timetables
/// need), addresses and places from Tramite's place search, or from Photon
/// when Tramite can't answer. Photon is asked only then, never alongside.
///
/// Tramite's suggestions have no position: [locate] asks for the one
/// picked, which also ends the search session (the provider bills a whole
/// session as that one lookup).
class PlaceFinder implements PlaceSearch, PlaceLocator {
  PlaceFinder({required this.motis, required this.tramite, PhotonClient? photon, DateTime Function()? now})
    : photon = photon ?? PhotonClient(),
      _now = now ?? DateTime.now;

  final MotisClient motis;
  final TramiteClient tramite;
  final PhotonClient photon;
  final DateTime Function() _now;

  String get _lang => motis.language;

  // ---- when Tramite is skipped ----

  /// The Tramite server that said it has no place search (501): skipped
  /// until the app points at another one.
  String? _noPlacesAt;

  /// Tramite asked not to come back before this (quota, rate limit), or
  /// failed: skipped until then.
  DateTime? _skipUntil;

  /// How long Tramite is skipped after it failed or was unreachable.
  static const _pause = Duration(minutes: 1);

  bool get _useTramite => _noPlacesAt != tramite.baseUrl && (_skipUntil == null || _now().isAfter(_skipUntil!));

  // ---- search session ----

  String? _session;
  DateTime? _sessionAt;

  /// One search's id, from its first letters to the place picked. A search
  /// quiet for a few minutes was abandoned: the next one starts afresh.
  String _sessionId() {
    final now = _now();
    if (_session == null || now.difference(_sessionAt!) > const Duration(minutes: 3)) _session = _uuid();
    _sessionAt = now;
    return _session!;
  }

  @override
  Future<List<Place>> search(String query, {LatLng? near}) async {
    Object? stopsError;
    final stops = motis.searchStops(query, near: near).catchError((Object e) {
      stopsError = e;
      return <Place>[];
    });
    List<Place> places;
    try {
      places = await _places(query, near);
    } catch (_) {
      await stops;
      if (stopsError != null) rethrow; // nothing at all to show
      places = const [];
    }
    return _interleave(await stops, places);
  }

  Future<List<Place>> _places(String query, LatLng? near) async {
    if (near != null && _useTramite) {
      try {
        return (await tramite.placeSuggestions(query, near: near, lang: _lang, session: _sessionId())).places;
      } on TramiteException catch (e) {
        // 404: a Tramite from before place search, as good as 501.
        _skip(e, noEndpoint: e.status == 404);
      } catch (_) {
        _skipUntil = _now().add(_pause); // offline, timeout
      }
    }
    return photon.search(query, near: near, lang: _lang);
  }

  void _skip(TramiteException e, {bool noEndpoint = false}) {
    if (noEndpoint) {
      _noPlacesAt = tramite.baseUrl;
      return;
    }
    switch (e.status) {
      case 501:
        _noPlacesAt = tramite.baseUrl;
      case 429 || 503:
        _skipUntil = _now().add(e.retryAfter ?? _pause);
      case >= 500:
        _skipUntil = _now().add(_pause);
      default:
        break; // this query only (bad request)
    }
  }

  @override
  Future<Place> locate(Place p) async {
    if (!p.needsLocating) return p;
    try {
      final at = await tramite.placeLocation(p.placeId!, lang: _lang, session: _session);
      _session = null; // ended by the lookup
      return p.locatedAt(at);
    } catch (e) {
      if (e is TramiteException) _skip(e);
      // Tramite went away between the suggestion and the tap: find the
      // same place on OpenStreetMap.
      final found = await photon.search([p.name, ?p.subtitle].join(', '), near: p.position, lang: _lang);
      if (found.isEmpty) rethrow;
      return p.locatedAt(found.first.position);
    }
  }

  /// Stops and places taking turns, each in its own order (a stop number's
  /// stop, first in [stops], stays first).
  static List<Place> _interleave(List<Place> stops, List<Place> places) => [
    for (var i = 0; i < max(stops.length, places.length); i++) ...[
      if (i < stops.length) stops[i],
      if (i < places.length) places[i],
    ],
  ];

  static final _random = Random.secure();

  /// A random (v4) UUID.
  static String _uuid() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }
}
