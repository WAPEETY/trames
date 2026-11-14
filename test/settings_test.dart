import 'package:flutter_localizations/flutter_localizations.dart' show GlobalWidgetsLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;
import 'package:roma_transit/l10n/app_localizations.dart';
import 'package:roma_transit/settings.dart';
import 'package:roma_transit/settings_page.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

final _t = DateTime(2026, 11, 14, 17);

void main() {
  setUp(() => SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty());

  group('I like walking', () {
    bool walks(WalkLiking w, int walkMin) => w.policy.walkInsteadOfRide(
          rideDuration: const Duration(minutes: 10),
          rideArrival: _t.add(const Duration(minutes: 20)),
          walkArrival: _t.add(const Duration(minutes: 19)), // walking isn't slower
          walk: Duration(minutes: walkMin),
        );

    test('a lot: any walk that is not slower', () => expect(walks(WalkLiking.aLot, 25), isTrue));
    test('a bit: up to 12 min', () {
      expect(walks(WalkLiking.aBit, 12), isTrue);
      expect(walks(WalkLiking.aBit, 13), isFalse);
    });
    test('not at all: up to 5 min', () {
      expect(walks(WalkLiking.notAtAll, 5), isTrue);
      expect(walks(WalkLiking.notAtAll, 6), isFalse);
    });
    test('a short bus is walked when walking is at most 0 / 1 / 3 min later', () {
      expect([for (final w in WalkLiking.values) w.policy.shortRideSlack.inMinutes], [0, 1, 3]);
      bool walks(WalkLiking w) => w.policy.walkInsteadOfRide(
            rideDuration: const Duration(minutes: 3),
            rideArrival: _t,
            walkArrival: _t.add(const Duration(minutes: 2)),
            walk: const Duration(minutes: 4),
          );
      expect([for (final w in WalkLiking.values) walks(w)], [false, false, true]);
    });

    test('walking the whole way is suggested up to 8 / 15 / 30 min', () {
      expect([for (final w in WalkLiking.values) w.policy.suggestWalkMax.inMinutes], [8, 15, 30]);
    });
  });

  test('I prefer: one change fewer is worth max(floor, share) more, uncapped', () {
    const trip = Duration(minutes: 100);
    expect(RoutePreference.fastest.rank.penalty(trip), const Duration(minutes: 15));
    expect(RoutePreference.balanced.rank.penalty(trip), const Duration(minutes: 25));
    expect(RoutePreference.fewerChanges.rank.penalty(trip), const Duration(minutes: 30));
    expect(RoutePreference.balanced.rank.penalty(const Duration(minutes: 12)), const Duration(minutes: 5));
    expect(RoutePreference.fewerChanges.stayOn.threshold(const Duration(minutes: 20)), const Duration(minutes: 10));
  });

  test('defaults are the middle options; choices survive a restart', () async {
    final s = AppSettings();
    await s.load();
    expect(s.walkLiking, WalkLiking.aBit);
    expect(s.routePreference, RoutePreference.balanced);
    expect(s.walkSpeed, WalkSpeed.auto);
    expect(s.walkingSpeedKmh, 5.0);
    s.walkLiking = WalkLiking.aLot;
    s.walkSpeed = WalkSpeed.fast;
    s.routePreference = RoutePreference.fewerChanges;
    await Future<void>.delayed(Duration.zero);
    final again = AppSettings();
    await again.load();
    expect(again.walkLiking, WalkLiking.aLot);
    expect(again.routePreference, RoutePreference.fewerChanges);
    expect(again.walkSpeed, WalkSpeed.fast);
    expect(again.walkingSpeedKmh, 6.0);
  });

  test('the learned pace survives a restart and is used in Auto', () async {
    final s = AppSettings();
    await s.load();
    var heard = 0, settingsHeard = 0;
    s.calibration.addListener(() => heard++);
    s.addListener(() => settingsHeard++);
    final t0 = DateTime(2026, 11, 14, 17);
    // 3 min north at 4 km/h, then a stop.
    for (var sec = 0; sec <= 180; sec += 5) {
      s.observeWalking(WalkFix(
          position: LatLng(41.9 + sec * 4 / 3.6 / 111195, 12.5), time: t0.add(Duration(seconds: sec)), accuracy: 5));
    }
    s.observeWalking(WalkFix(position: const LatLng(42, 12.5), time: t0.add(const Duration(minutes: 10)), accuracy: 5));
    expect(heard, 1);
    expect(settingsHeard, 0); // journeys on screen aren't re-planned
    final learned = s.walkingSpeedKmh;
    expect(learned, lessThan(5.0));
    await Future<void>.delayed(Duration.zero);
    final again = AppSettings();
    await again.load();
    expect(again.walkingSpeedKmh, learned);
    expect(again.calibrator.minutes, closeTo(3, 0.2));
    again.resetCalibration();
    expect(again.walkingSpeedKmh, 5.0);
  });

  testWidgets('the page changes the settings', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 2.75;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true),
      builder: (context, c) => M3ETheme(
        data: M3EThemeData.fromMaterial(Theme.of(context)),
        initialTheme: Brightness.light,
        child: c!,
      ),
      home: const SettingsPage(),
    ));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await t.tap(find.text('Not at all'));
    await t.pumpAndSettle();
    expect(appSettings.walkLiking, WalkLiking.notAtAll);
    expect(find.textContaining('at most 5 min'), findsOneWidget);
    expect(find.textContaining('Current speed: 5.0 km/h'), findsOneWidget);
    await t.tap(find.text('Slow'));
    await t.pumpAndSettle();
    expect(appSettings.walkSpeed, WalkSpeed.slow);
    expect(find.textContaining('assume 4.0 km/h'), findsOneWidget);
    await t.ensureVisible(find.text('Fewer changes'));
    await t.pumpAndSettle();
    await t.tap(find.text('Fewer changes'));
    await t.pumpAndSettle();
    expect(appSettings.routePreference, RoutePreference.fewerChanges);
    await t.ensureVisible(find.text('Advanced'));
    await t.pumpAndSettle();
    await t.tap(find.text('Advanced'));
    await t.pumpAndSettle();
    expect(find.textContaining('enriches MOTIS'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
