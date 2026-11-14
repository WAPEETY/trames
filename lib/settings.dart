import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backend/walk_calibrator.dart';
import 'backend/walk_rules.dart' show WalkPolicy;
import 'backend/cities.dart' show kTramiteUrl;
import 'backend/config.dart';
import 'backend/preferences.dart';
import 'backend/route_search.dart' show RankPolicy;

export 'backend/preferences.dart';
export 'backend/walk_calibrator.dart' show WalkFix;

/// The user's settings, on the device. Defaults are the middle options.
class AppSettings extends ChangeNotifier {
  AppSettings({SharedPreferencesAsync? prefs}) : _prefs = prefs ?? SharedPreferencesAsync();
  final SharedPreferencesAsync _prefs;

  WalkLiking _walk = WalkLiking.aBit;
  WalkSpeed _speed = WalkSpeed.auto;
  RoutePreference _prefer = RoutePreference.balanced;

  /// Learns your pace while you walk; its value is used in [WalkSpeed.auto].
  final calibrator = WalkCalibrator();

  /// The learned pace changed (not a setting the user changed: journeys on
  /// screen aren't re-planned, the next search uses it).
  Listenable get calibration => _calibration;
  final _calibration = _Signal();
  String _motisUrl = kMotisUrl;
  String _tramiteUrl = kTramiteUrl;

  WalkLiking get walkLiking => _walk;
  WalkSpeed get walkSpeed => _speed;

  /// The walking pace to plan with, km/h.
  double get walkingSpeedKmh => _speed.kmh ?? calibrator.kmh;
  RoutePreference get routePreference => _prefer;
  String get motisUrl => _motisUrl;
  String get tramiteUrl => _tramiteUrl;

  WalkPolicy get walkPolicy => _walk.policy;
  RankPolicy get rankPolicy => _prefer.rank;

  static const _kWalk = 'settings.walkLiking';
  static const _kSpeed = 'settings.walkSpeed';
  static const _kLearnedKmh = 'settings.walkLearnedKmh';
  static const _kLearnedMinutes = 'settings.walkLearnedMinutes';
  static const _kPrefer = 'settings.routePreference';
  static const _kMotis = 'settings.motisUrl';
  static const _kTramite = 'settings.tramiteUrl';

  /// Reads what was saved and points the app at the chosen servers.
  Future<void> load() async {
    try {
      _walk = WalkLiking.values.asNameMap()[await _prefs.getString(_kWalk)] ?? _walk;
      _speed = WalkSpeed.values.asNameMap()[await _prefs.getString(_kSpeed)] ?? _speed;
      calibrator.kmh = await _prefs.getDouble(_kLearnedKmh) ?? calibrator.kmh;
      calibrator.minutes = await _prefs.getDouble(_kLearnedMinutes) ?? calibrator.minutes;
      _prefer = RoutePreference.values.asNameMap()[await _prefs.getString(_kPrefer)] ?? _prefer;
      _motisUrl = await _prefs.getString(_kMotis) ?? _motisUrl;
      _tramiteUrl = await _prefs.getString(_kTramite) ?? _tramiteUrl;
    } catch (_) {
      // no storage (tests, web private mode): defaults
    }
    useServers(motis: _motisUrl, tramiteUrl: _tramiteUrl);
    useWalkingSpeed(walkingSpeedKmh);
    notifyListeners();
  }

  set walkLiking(WalkLiking v) {
    if (v == _walk) return;
    _walk = v;
    _save(_kWalk, v.name);
  }

  set walkSpeed(WalkSpeed v) {
    if (v == _speed) return;
    _speed = v;
    _save(_kSpeed, v.name);
  }

  /// A GPS fix while the app is open ([riding]: you said you're on a
  /// vehicle). Saves the pace when it was learned from a walk.
  void observeWalking(WalkFix fix, {bool riding = false}) {
    if (calibrator.add(fix, riding: riding) == null) return;
    _saveLearned();
  }

  /// Starts learning your pace again from 5 km/h.
  void resetCalibration() {
    calibrator.reset();
    _saveLearned();
  }

  void _saveLearned() {
    _calibration.ping();
    _prefs.setDouble(_kLearnedKmh, calibrator.kmh).catchError((Object _) {});
    _prefs.setDouble(_kLearnedMinutes, calibrator.minutes).catchError((Object _) {});
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

class _Signal extends ChangeNotifier {
  void ping() => notifyListeners();
}
