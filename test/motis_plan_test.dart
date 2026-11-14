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
}
