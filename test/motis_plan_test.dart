import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/motis.dart';

Map<String, dynamic> _place(String stop, double lat) =>
    {'name': stop, 'stopId': 'it-Lazio-Rome_$stop', 'lat': lat, 'lon': 12.5};

Map<String, dynamic> _walk(String from, String to, num distance, String a, String b) => {
      'mode': 'WALK', 'from': _place(from, 41.90), 'to': _place(to, 41.90), 'distance': distance,
      'startTime': a, 'endTime': b, 'duration': 120,
    };

Map<String, dynamic> _ride(String line, String from, String to, String a, String b) => {
      'mode': 'BUS', 'from': _place(from, 41.90), 'to': _place(to, 41.91), 'routeShortName': line,
      'tripId': '20261112_26:00_it-Lazio-Rome_0#$line', 'directionId': '1', 'startTime': a, 'endTime': b,
    };

void main() {
  test('a same-stop transfer "walk" is not a leg', () async {
    final body = jsonEncode({
      'itineraries': [
        {
          'startTime': '2026-11-13T08:00:00Z',
          'endTime': '2026-11-13T08:40:00Z',
          'transfers': 1,
          'legs': [
            _walk('home', '1', 300, '2026-11-13T08:00:00Z', '2026-11-13T08:04:00Z'),
            _ride('88', '1', '2', '2026-11-13T08:04:00Z', '2026-11-13T08:15:00Z'),
            _walk('2', '2', 0, '2026-11-13T08:15:00Z', '2026-11-13T08:17:00Z'), // same stop
            _ride('60', '2', '3', '2026-11-13T08:20:00Z', '2026-11-13T08:38:00Z'),
            _walk('3', 'end', 150, '2026-11-13T08:38:00Z', '2026-11-13T08:40:00Z'),
          ],
        },
      ],
      'direct': [],
    });
    final client = MotisClient(client: MockClient((_) async => http.Response(body, 200)));
    final its = await client.plan(const LatLng(41.9, 12.5), const LatLng(41.91, 12.5));
    expect(its.single.legs.map((l) => l.routeShortName ?? 'walk'), ['walk', '88', '60', 'walk']);
    // A ride knows its boarding and alighting stops (to follow it in Tramite).
    expect(its.single.legs[1].fromStopId, 'it-Lazio-Rome_1');
    expect(its.single.legs[1].toStopId, 'it-Lazio-Rome_2');
  });

  test('the same run under another trip id: same date, start and line at the stop', () async {
    final body = jsonEncode({
      'stopTimes': [
        {'tripId': '20261114_03:50_it-Lazio-Cotral_158245687', 'routeShortName': 'VT1A'},
        {'tripId': '20261114_03:50_it-Lazio-Cotral_158245690', 'routeShortName': 'CC597A'},
        {'tripId': '20261114_04:20_it-Lazio-Cotral_158245700', 'routeShortName': 'CC597A'},
      ],
    });
    Uri? asked;
    final client = MotisClient(client: MockClient((req) async {
      asked = req.url;
      return http.Response(body, 200);
    }));
    final at = DateTime.utc(2026, 11, 14, 3, 54, 2, 294, 801);
    final id = await client.sameRun('20261114_03:50_it-Lazio-Cotral_158352099',
        stopId: 'it-Lazio-Cotral_f14084', at: at, line: 'CC597A');
    expect(id, '20261114_03:50_it-Lazio-Cotral_158245690');
    expect(asked?.queryParameters['stopId'], 'it-Lazio-Cotral_f14084');
    // Whole seconds: Transitous misreads microseconds (days off).
    expect(asked?.queryParameters['time'], '2026-11-14T03:49:02Z');
    expect(await client.sameRun('20261114_05:00_it-Lazio-Cotral_1', stopId: 'x', at: at, line: 'CC597A'), isNull);
  });
}
