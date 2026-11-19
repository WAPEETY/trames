import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/motis.dart';
import 'package:roma_transit/backend/photon.dart';
import 'package:roma_transit/backend/place_finder.dart';

const rome = LatLng(41.9, 12.5);

/// MOTIS geocode: one stop.
http.Response motisStops(http.Request req) {
  expect(req.url.queryParameters['type'], 'STOP');
  return http.Response(
      jsonEncode([
        {'type': 'STOP', 'name': 'COLOSSEO', 'id': 'it-Lazio-Rome_AB1', 'lat': 41.891, 'lon': 12.492, 'modes': ['SUBWAY']},
      ]),
      200);
}

final photonBody = jsonEncode({
  'features': [
    {
      'properties': {'osm_key': 'tourism', 'osm_value': 'attraction', 'type': 'house', 'name': 'Colosseo', 'street': 'Piazza del Colosseo', 'city': 'Roma'},
      'geometry': {'coordinates': [12.4922, 41.8902]},
    },
    {
      'properties': {'osm_key': 'highway', 'osm_value': 'bus_stop', 'name': 'Colosseo'},
      'geometry': {'coordinates': [12.49, 41.89]},
    },
    {
      'properties': {'osm_key': 'place', 'osm_value': 'house', 'type': 'house', 'street': 'Via del Corso', 'housenumber': '12', 'locality': 'Campo Marzio', 'city': 'Roma'},
      'geometry': {'coordinates': [12.477, 41.909]},
    },
  ],
});

class Fixture {
  Fixture({this.tramiteAnswer});

  /// Tramite's answer to place requests; null: unreachable.
  http.Response Function(http.Request req)? tramiteAnswer;
  final tramiteCalls = <Uri>[];
  var photonCalls = 0;
  var now = DateTime(2026, 11, 19, 12);

  late final finder = PlaceFinder(
    motis: MotisClient(client: MockClient((req) async => motisStops(req))),
    tramite: TramiteClient(
      baseUrl: 'https://tramite.test',
      client: MockClient((req) async {
        tramiteCalls.add(req.url);
        final a = tramiteAnswer;
        if (a == null) throw http.ClientException('offline');
        return a(req);
      }),
    ),
    photon: PhotonClient(client: MockClient((req) async {
      photonCalls++;
      return http.Response(photonBody, 200);
    })),
    now: () => now,
  );
}

http.Response tramiteOk(http.Request req) {
  if (req.url.path == '/v1/places/autocomplete') {
    return http.Response(
        jsonEncode({
          'attribution': 'Google Maps',
          'results': [
            {'id': 'google:P1', 'name': 'Colosseo', 'subtitle': 'Piazza del Colosseo, Roma', 'kind': 'place', 'distanceMeters': 850},
            {'id': 'google:P2', 'name': 'Via del Corso 1', 'subtitle': '', 'kind': 'address'},
          ],
        }),
        200);
  }
  if (req.url.path == '/v1/places/google:P1') return http.Response(jsonEncode({'id': 'google:P1', 'lat': 41.8902, 'lon': 12.4922}), 200);
  return http.Response('{"error":"not_found"}', 404);
}

void main() {
  test('Tramite places and MOTIS stops take turns; Photon is not asked', () async {
    final f = Fixture(tramiteAnswer: tramiteOk);
    final res = await f.finder.search('colos', near: rome);
    expect(res.map((p) => p.name), ['COLOSSEO', 'Colosseo', 'Via del Corso 1']);
    expect(res[0].stopId, 'it-Lazio-Rome_AB1');
    final g = res[1];
    expect((g.needsLocating, g.placeId, g.credit, g.distanceHint), (true, 'google:P1', 'Google Maps', 850));
    expect(res[2].subtitle, isNull);
    expect(f.photonCalls, 0);
    final q = f.tramiteCalls.single.queryParameters;
    expect((q['q'], q['near'], q['lang']), ('colos', '41.9,12.5', 'it'));
    final session = q['session']!;
    expect(session, hasLength(36));

    // Same search, next letters: same session; the pick ends it.
    await f.finder.search('colosseo', near: rome);
    expect(f.tramiteCalls.last.queryParameters['session'], session);
    final located = await f.finder.locate(g);
    expect((located.needsLocating, located.position.latitude, located.placeId, located.credit), (false, 41.8902, 'google:P1', 'Google Maps'));
    expect(f.tramiteCalls.last.queryParameters['session'], session);
    await f.finder.search('termini', near: rome);
    expect(f.tramiteCalls.last.queryParameters['session'], isNot(session));
  });

  test('no place search on Tramite (501): Photon, and Tramite is not asked again', () async {
    final f = Fixture(tramiteAnswer: (_) => http.Response('{"error":"unavailable"}', 501));
    final res = await f.finder.search('colos', near: rome);
    // The OSM bus stop is left out: the stop comes from MOTIS.
    expect(res.map((p) => (p.name, p.kind)), [
      ('COLOSSEO', PlaceKind.stop),
      ('Colosseo', PlaceKind.place),
      ('Via del Corso 12', PlaceKind.address),
    ]);
    expect(res[1].subtitle, 'Piazza del Colosseo, Roma');
    expect(res[2].subtitle, 'Campo Marzio, Roma');
    expect(res[1].needsLocating, false);
    await f.finder.search('colosseo', near: rome);
    expect((f.tramiteCalls.length, f.photonCalls), (1, 2));
  });

  test('a Tramite without place search endpoints (404) counts as none', () async {
    final f = Fixture(tramiteAnswer: (_) => http.Response('404 page not found', 404));
    await f.finder.search('colos', near: rome);
    await f.finder.search('colosseo', near: rome);
    expect((f.tramiteCalls.length, f.photonCalls), (1, 2));
  });

  test('quota (503) waits Retry-After; unreachable waits a minute', () async {
    final f = Fixture(tramiteAnswer: (_) => http.Response('{"error":"quota"}', 503, headers: {'retry-after': '120'}));
    await f.finder.search('colos', near: rome);
    f.now = f.now.add(const Duration(seconds: 119));
    await f.finder.search('colos', near: rome);
    expect((f.tramiteCalls.length, f.photonCalls), (1, 2));
    f.now = f.now.add(const Duration(seconds: 2));
    f.tramiteAnswer = null; // and now it is offline
    await f.finder.search('colos', near: rome);
    expect((f.tramiteCalls.length, f.photonCalls), (2, 3));
    f.now = f.now.add(const Duration(seconds: 30));
    await f.finder.search('colos', near: rome);
    expect(f.tramiteCalls.length, 2);
    f.now = f.now.add(const Duration(seconds: 31));
    f.tramiteAnswer = tramiteOk;
    final res = await f.finder.search('colos', near: rome);
    expect((f.tramiteCalls.length, f.photonCalls, res[1].placeId), (3, 4, 'google:P1'));
  });

  test('a pick Tramite can no longer locate is found on Photon', () async {
    final f = Fixture(tramiteAnswer: tramiteOk);
    final g = (await f.finder.search('colos', near: rome))[1];
    f.tramiteAnswer = null;
    final located = await f.finder.locate(g);
    expect((located.needsLocating, located.name), (false, 'Colosseo'));
    expect(located.position.longitude, closeTo(12.4922, 1e-9));
    expect(f.photonCalls, 1);
  });

  test('unlocated suggestions rank by the distance their search gave', () {
    const far = LatLng(45.46, 9.19); // Milano
    final ranked = rankByProximity([
      const Place.unlocated(placeId: 'g:far', name: 'Far', position: rome, distanceHint: 400000),
      const Place(name: 'Milano stop', position: far),
      const Place.unlocated(placeId: 'g:near', name: 'Near', position: rome),
    ], rome);
    expect(ranked.map((p) => p.name), ['Near', 'Far', 'Milano stop']);
  });
}
