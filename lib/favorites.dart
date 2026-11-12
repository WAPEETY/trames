import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backend/backend.dart';

/// Favourite stops and destinations, kept on the device.
///
/// A favourite is just a [Place] (stops carry their stop id, so their
/// timetable still opens). Listeners are notified on every change so star
/// buttons update in place.
class FavoritesStore extends ChangeNotifier {
  FavoritesStore({SharedPreferencesAsync? prefs}) : _prefs = prefs ?? SharedPreferencesAsync();

  static const _key = 'favorites.v1';
  final SharedPreferencesAsync _prefs;
  final List<Place> _items = [];

  List<Place> get stops => [for (final p in _items) if (p.kind == PlaceKind.stop) p];
  List<Place> get destinations => [for (final p in _items) if (p.kind != PlaceKind.stop) p];

  Future<void> load() async {
    try {
      final raw = await _prefs.getString(_key);
      if (raw == null) return;
      _items
        ..clear()
        ..addAll((jsonDecode(raw) as List).map((j) => _fromJson(j as Map<String, dynamic>)));
      notifyListeners();
    } catch (_) {
      // Unreadable data: start empty rather than fail.
    }
  }

  bool isFavorite(Place p) => _items.any((f) => keyOf(f) == keyOf(p));

  Future<void> toggle(Place p) async {
    final k = keyOf(p);
    final i = _items.indexWhere((f) => keyOf(f) == k);
    if (i >= 0) {
      _items.removeAt(i);
    } else {
      _items.add(p);
    }
    notifyListeners();
    await _prefs.setString(_key, jsonEncode([for (final f in _items) _toJson(f)]));
  }

  /// Same stop id, or same name at (about) the same spot.
  static String keyOf(Place p) =>
      p.stopId ?? '${p.name.toLowerCase()}@${p.position.latitude.toStringAsFixed(4)},${p.position.longitude.toStringAsFixed(4)}';

  static Map<String, dynamic> _toJson(Place p) => {
        'name': p.name,
        'subtitle': p.subtitle,
        'lat': p.position.latitude,
        'lon': p.position.longitude,
        'kind': p.kind.name,
        'stopId': p.stopId,
        'station': p.station,
      };

  static Place _fromJson(Map<String, dynamic> j) => Place(
        name: j['name'] as String,
        subtitle: j['subtitle'] as String?,
        position: LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()),
        kind: PlaceKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => PlaceKind.place),
        stopId: j['stopId'] as String?,
        station: j['station'] as bool? ?? false,
      );
}
