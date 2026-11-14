// Live: rule 2 ("the 63 already takes you there") on Largo Somalia ->
// Via Jacopone da Todi, the case it was made for.
@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/config.dart';
import 'package:roma_transit/backend/preferences.dart';
import 'package:roma_transit/backend/route_search.dart';

void main() {
  test('Largo Somalia -> Via Jacopone da Todi', () async {
    final b = createBackend(city: kCities.first);
    final search = RouteSearch(
      b.planner,
      walks: WalkCache(b.walks!),
      trips: b.trips,
      policy: WalkLiking.aBit.policy,
      rank: RoutePreference.balanced.rank,
      stayOn: RoutePreference.balanced.stayOn,
    );
    final groups = await search.search(const LatLng(41.9361, 12.5143), const LatLng(41.9418, 12.5543),
        toName: 'Via Jacopone da Todi');
    String hm(DateTime t) => t.toIso8601String().substring(11, 16);
    for (final g in groups) {
      final it = g.best;
      // ignore: avoid_print
      print('${g.hiddenBecause == null ? 'shown ' : 'HIDDEN (${g.hiddenBecause})'} '
          '${hm(it.start)}-${hm(it.end)} changes=${it.transfers} ${g.signature}  tags=${g.tags.map((t) => t.name).join(',')}');
    }
    expect(groups.where((g) => g.hiddenBecause == null), isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
