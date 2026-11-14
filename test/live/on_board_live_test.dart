// Live: planning from a bus you're riding (Transitous client offsets).
@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/config.dart';
import 'package:roma_transit/backend/motis.dart';
import 'package:roma_transit/backend/route_search.dart';

void main() {
  test('on the 64 after Termini: routes start on board, staying on first', () async {
    final b = createBackend(city: kCities.first);
    // A 64 leaving Termini soon; pretend it's a minute after it left.
    const termini = LatLng(41.9010, 12.5010), sanPietro = LatLng(41.9022, 12.4539);
    final its = await b.planner.plan(termini, sanPietro, options: const PlanOptions(maxTransfers: 0));
    final leg = its.expand((it) => it.transitLegs).where((l) => l.routeShortName == '64').firstOrNull;
    if (leg == null) {
      markTestSkipped('no 64 from Termini right now');
      return;
    }
    final ride = OnBoardRide(
      backendTripId: leg.backendTripId!,
      tripId: MotisClient.rawTripId(leg.backendTripId)!,
      line: '64',
      mode: 'BUS',
      headsign: leg.headsign ?? '',
    );
    final now = leg.start.add(const Duration(minutes: 1));
    final search = RouteSearch(b.planner, walks: WalkCache(b.walks!), trips: b.trips, clock: () => now);

    void show(String title, List<RouteGroup> groups) {
      // ignore: avoid_print
      print('--- $title (on the 64 at ${now.toIso8601String().substring(11, 16)})');
      for (final g in groups) {
        final it = g.best;
        // ignore: avoid_print
        print('${g.hiddenBecause == null ? '' : 'HIDDEN '}${g.tags.map((t) => t.name).join(',').padRight(24)} arrive ${it.end.toIso8601String().substring(11, 16)} '
            'changes=${it.transfers} ${it.legs.map((l) => l.onBoard ? '64→${l.toName}' : l.transit ? '${l.routeShortName}' : 'walk${l.duration.inMinutes}').join(' › ')}');
      }
    }

    // Near the 64's stop at Cavalleggeri: staying on should win.
    final cav = await search.searchOnBoard(ride, const LatLng(41.8995, 12.4540), toName: 'Cavalleggeri');
    show('to Cavalleggeri', cav);
    expect(cav, isNotEmpty);
    expect(cav.every((g) => g.best.legs.first.onBoard), isTrue);
    expect(staysOnBoard(cav.first.best), isTrue);
    expect(cav.first.tags, contains(RouteTag.stayOnBoard));

    // Viale Trastevere: off the 64 for a bus or tram.
    final tras = await search.searchOnBoard(ride, const LatLng(41.8836, 12.4705), toName: 'Viale Trastevere');
    show('to Viale Trastevere', tras);
    expect(tras, isNotEmpty);
    expect(tras.every((g) => g.best.legs.first.onBoard && g.best.start == now), isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
