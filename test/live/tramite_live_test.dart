// Tramite through the app's client and live connection:
//   flutter test --tags live test/live/tramite_live_test.dart
// Against another Tramite: --dart-define=TRAMITE_URL=http://localhost:8080
@Tags(['live'])
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/live_connection.dart';

const pugliese = 'it-Lazio-Rome_71527';

void main() {
  final t = TramiteClient(baseUrl: kTramiteUrl);
  final live = LiveConnection(t);
  tearDownAll(live.pause);

  Future<Object?> first(String topic) {
    final c = Completer<Object?>();
    late LiveSubscription sub;
    sub = live.subscribe(topic, (data) {
      if (!c.isCompleted) c.complete(data);
      sub.cancel();
    });
    return c.future.timeout(const Duration(seconds: 15));
  }

  test('coverage', () async {
    await t.loadCoverage();
    expect(t.covers(pugliese), isTrue, reason: 'prefixes: ${t.prefixes}');
  });

  test('a stop board, then one of its trips at that stop', () async {
    await t.loadCoverage();
    final rows = TramiteClient.parseRows(await first(TramiteClient.departuresTopic(pugliese)));
    // ignore: avoid_print
    print('${rows.length} departures: ${rows.take(4).map((r) => '${r.item.line} ${r.departure.time.toIso8601String().substring(11, 16)} ${r.departure.certainty?.name}').join(', ')}');
    if (rows.isEmpty) return; // night: nothing scheduled
    final trip = rows.first.departure.backendTripId!;
    final one = TramiteClient.parseRows(await first(TramiteClient.departuresTopic(pugliese, tripId: trip)));
    expect(one.single.departure.backendTripId, trip);
  });

  test('a line and an area', () async {
    await t.loadCoverage();
    final line = TramiteClient.parseVehicles(await first(TramiteClient.lineTopic(TramiteClient.lineId('it-Lazio-Rome', '60'))));
    for (final b in line) {
      expect(b.vehicle.routeShortName, '60');
    }
    final area = await first('bbox=41.88000,12.47000,41.91000,12.51000');
    // ignore: avoid_print
    print('line 60: ${line.length} buses, area: ${TramiteClient.parseVehicles(area).length} buses');
  });
}
