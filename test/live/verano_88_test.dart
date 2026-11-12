// Live regression: the direct 88 Verano -> Conca d'Oro must be offered.
@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/config.dart';
import 'package:roma_transit/backend/route_search.dart';

void main() {
  test('direct 88 Verano -> Conca d\'Oro is listed', () async {
    final b = transitousRome();
    final groups = await RouteSearch(b.planner, walks: WalkCache(b.walks!))
        .search(const LatLng(41.90215, 12.51899), const LatLng(41.94003, 12.52944));
    for (final g in groups) {
      final it = g.best;
      // ignore: avoid_print
      print('${(g.isWalk ? 'WALK' : g.signature).padRight(22)} ${it.start.toLocal().toIso8601String().substring(11, 16)}'
          '->${it.end.toLocal().toIso8601String().substring(11, 16)} walk ${it.walkMinutes}m ${g.isLive ? 'live' : 'sched'} '
          'tags=${g.tags.map((t) => t.name)} ${it.transitLegs.map((l) => '${l.routeShortName}:${l.fromName}->${l.toName}').join(' ')}');
    }
    // Alternatives only from (about) the same stops: the 88 from Verano is not
    // an alternative to the metro from Policlinico (~900 m away).
    for (final g in groups) {
      for (final l in g.best.transitLegs) {
        for (final a in l.alternatives) {
          expect(distanceMeters(a.ride.from, l.from), lessThanOrEqualTo(300), reason: '${g.signature}: ${a.line} boards far');
          expect(distanceMeters(a.ride.to, l.to), lessThanOrEqualTo(300), reason: '${g.signature}: ${a.line} alights far');
        }
      }
    }
    final metro = groups.where((g) => g.signature == 'MEB1');
    if (metro.isNotEmpty) {
      expect(metro.first.best.transitLegs.single.alternatives.map((a) => a.line), isNot(contains('88')));
    }
    final direct88 = groups.where((g) => g.signature == '88');
    expect(direct88.first.isLive, isFalse);
    expect(direct88, isNotEmpty);
    expect(direct88.first.best.transitLegs.single.toName.toUpperCase(), contains("CONCA D'ORO"));
  }, timeout: const Timeout(Duration(seconds: 120)));
}
