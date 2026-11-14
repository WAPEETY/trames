import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backend/walk_rules.dart' show WalkPolicy;
import 'backend/cities.dart' show kTramiteUrl;
import 'backend/config.dart';
import 'backend/preferences.dart';
import 'backend/route_search.dart' show RankPolicy;

export 'backend/preferences.dart';

/// The user's settings, on the device. Defaults are the middle options.
class AppSettings extends ChangeNotifier {
  AppSettings({SharedPreferencesAsync? prefs}) : _prefs = prefs ?? SharedPreferencesAsync();
  final SharedPreferencesAsync _prefs;

  WalkLiking _walk = WalkLiking.aBit;
  RoutePreference _prefer = RoutePreference.balanced;
  String _motisUrl = kMotisUrl;
  String _tramiteUrl = kTramiteUrl;

  WalkLiking get walkLiking => _walk;
  RoutePreference get routePreference => _prefer;
  String get motisUrl => _motisUrl;
  String get tramiteUrl => _tramiteUrl;

  WalkPolicy get walkPolicy => _walk.policy;
  RankPolicy get rankPolicy => _prefer.rank;

  static const _kWalk = 'settings.walkLiking';
  static const _kPrefer = 'settings.routePreference';
  static const _kMotis = 'settings.motisUrl';
  static const _kTramite = 'settings.tramiteUrl';

  /// Reads what was saved and points the app at the chosen servers.
  Future<void> load() async {
    try {
      _walk = WalkLiking.values.asNameMap()[await _prefs.getString(_kWalk)] ?? _walk;
      _prefer = RoutePreference.values.asNameMap()[await _prefs.getString(_kPrefer)] ?? _prefer;
      _motisUrl = await _prefs.getString(_kMotis) ?? _motisUrl;
      _tramiteUrl = await _prefs.getString(_kTramite) ?? _tramiteUrl;
    } catch (_) {
      // no storage (tests, web private mode): defaults
    }
    useServers(motis: _motisUrl, tramiteUrl: _tramiteUrl);
    notifyListeners();
  }

  set walkLiking(WalkLiking v) {
    if (v == _walk) return;
    _walk = v;
    _save(_kWalk, v.name);
  }

  set routePreference(RoutePreference v) {
    if (v == _prefer) return;
    _prefer = v;
    _save(_kPrefer, v.name);
  }

  /// Switches servers (already checked by the caller); the defaults clear
  /// the saved value.
  void setServers({required String motis, required String tramite}) {
    if (motis == _motisUrl && tramite == _tramiteUrl) return;
    _motisUrl = motis;
    _tramiteUrl = tramite;
    useServers(motis: motis, tramiteUrl: tramite);
    _save(_kMotis, motis == kMotisUrl ? null : motis);
    _save(_kTramite, tramite == kTramiteUrl ? null : tramite);
  }

  void _save(String key, String? value) {
    notifyListeners();
    (value == null ? _prefs.remove(key) : _prefs.setString(key, value)).catchError((Object _) {});
  }
}

/// The app's settings (loaded in main).
final appSettings = AppSettings();
