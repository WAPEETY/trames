import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/live_connection.dart';

/// Tramite answers shaped as served by tramite.realac.ci (trimmed).
Map<String, dynamic> stopTime(String trip, String sched, String dep,
        {bool realTime = false, String reason = 'NO_RT_DATA', Map<String, dynamic>? vehicle}) =>
    {
      'source': 'rome',
      'tripId': '20261113_${sched.substring(11, 16)}_it-Lazio-Rome_$trip',
      'gtfsTripId': trip,
      'serviceDate': '20261113',
      'routeId': 'it-Lazio-Rome_60',
      'routeShortName': '60',
      'routeType': 3,
      'directionId': 1,
      'headsign': 'P.ZA VENEZIA',
      'stopId': 'it-Lazio-Rome_71527',
      'stopSequence': 1,
      'scheduledDeparture': sched,
      'departure': dep,
      'scheduledArrival': sched,
      'arrival': dep,
      'realTime': realTime,
      'departureTimestampReason': reason,
      'tripFrom': {'stopId': 'it-Lazio-Rome_71527', 'name': 'LGO PUGLIESE', 'lat': 41.946, 'lon': 12.554},
      'tripTo': {'stopId': 'it-Lazio-Rome_70038', 'name': 'P.ZA VENEZIA', 'lat': 41.896, 'lon': 12.482},
      'vehicle': ?vehicle,
    };

void main() {
  final stop = Stop(id: 'it-Lazio-Rome_71527', name: 'LGO PUGLIESE', position: const LatLng(41.946, 12.554), distanceMeters: 0);

  test('board rows: waiting bus with its position, inferred late, timetable', () {
    final rows = TramiteClient.parseRows({
      'stopTimes': [
        stopTime('0#2384-15', '2026-11-13T13:33:00Z', '2026-11-13T13:44:54Z', realTime: true, reason: 'PREDICTED', vehicle: {
          'id': '5039',
          'started': false,
          'currentStopSequence': 1,
          'lat': 41.946,
          'lon': 12.554,
          'timestamp': '2026-11-13T13:43:36Z',
        }),
        stopTime('0#2363-9', '2026-11-13T13:49:00Z', '2026-11-13T13:56:06Z', reason: 'INFERRED', vehicle: {'id': '5088'}),
        stopTime('0#2346-14', '2026-11-13T13:56:00Z', '2026-11-13T13:56:00Z'),
      ],
    });
    expect(rows.map((r) => r.departure.certainty), [Certainty.waiting, Certainty.estimated, Certainty.scheduled]);
    expect(rows[0].bus?.id, '5039');
    expect(rows[0].bus?.started, isFalse);
    expect(rows[0].departure.backendTripId, '20261113_13:33_it-Lazio-Rome_0#2384-15');
    expect(rows[0].departure.stopId, 'it-Lazio-Rome_71527');
    expect(rows[1].inferred, isTrue);
    expect(rows[1].bus, isNull, reason: 'an inferred bus is on another trip: no position here');
    expect(rows[1].departure.time.difference(rows[1].scheduled), const Duration(seconds: 426));
    final board = TramiteClient.parseBoard({'stopTimes': [stopTime('a', '2026-11-13T13:33:00Z', '2026-11-13T13:33:00Z')]}, stop);
    expect(board.single.line, '60');
    expect(board.single.stop, stop);
  });

  test('vehicles with their line colour', () {
    final vs = TramiteClient.parseVehicles([
      {'source': 'rome', 'id': '5039', 'routeShortName': '60', 'routeColor': 'D02F2F', 'gtfsTripId': '0#2384-15',
        'tripId': '20261113_14:33_it-Lazio-Rome_0#2384-15', 'directionId': 1, 'lat': 41.946, 'lon': 12.554,
        'currentStopSequence': 1, 'timestamp': '2026-11-13T13:43:36Z'},
    ]);
    expect(vs.single.color, '#D02F2F');
    expect(vs.single.vehicle.backendTripId, '20261113_14:33_it-Lazio-Rome_0#2384-15');
    expect(vs.single.vehicle.started, isFalse);
  });

  test('coverage: by id prefix, for stops, lines and trips', () async {
    final t = TramiteClient(
      baseUrl: 'https://tramite.test',
      client: MockClient((req) async => http.Response(
          jsonEncode([
            {'id': 'rome', 'idPrefix': 'it-Lazio-Rome'},
          ]),
          200)),
    );
    expect(t.covers('it-Lazio-Rome_71527'), isFalse, reason: 'unknown until Tramite answers');
    await t.loadCoverage();
    expect(t.covers('it-Lazio-Rome_71527'), isTrue);
    expect(t.covers('20261113_14:33_it-Lazio-Rome_0#2384-15'), isTrue);
    expect(t.covers('it-Lazio-Cotral_123'), isFalse);
    expect(t.covers('20261113_14:33_it-Lazio-Cotral_9'), isFalse);
    expect(t.prefixOf('it-Lazio-Rome_60'), 'it-Lazio-Rome');
    expect(TramiteClient.lineId('it-Lazio-Rome', '85'), 'it-Lazio-Rome_85');
    expect(TramiteClient.departuresTopic('it-Lazio-Rome_71527', tripId: 'T'), 'departures=it-Lazio-Rome_71527,trip=T');
    expect(TramiteClient.departuresTopic('it-Lazio-Cotral_f13889', tripId: 'T', lineId: 'it-Lazio-Cotral_MR1A'),
        'departures=it-Lazio-Cotral_f13889,trip=T,line=it-Lazio-Cotral_MR1A');
  });

  test('coverage: unreachable Tramite covers nothing', () async {
    final t = TramiteClient(baseUrl: 'https://tramite.test', client: MockClient((_) async => http.Response('', 503)));
    await t.loadCoverage();
    expect(t.prefixes, isEmpty);
    expect(t.covers('it-Lazio-Rome_71527'), isFalse);
  });

  group('live connection', () {
    late _FakeTramite server;
    late LiveConnection live;
    setUp(() async {
      server = await _FakeTramite.start();
      live = LiveConnection(TramiteClient(baseUrl: server.url));
    });
    tearDown(() async {
      live.pause();
      await server.close();
    });

    test('subscribing sends one batch and delivers the current state, then changes', () async {
      final a = <Object?>[], b = <Object?>[];
      final subA = live.subscribe('line=it-Lazio-Rome_60', a.add);
      live.subscribe('bbox=1,2,3,4', b.add);
      await server.waitForTopics({'line=it-Lazio-Rome_60', 'bbox=1,2,3,4'});
      expect(server.posts, hasLength(1), reason: 'both topics in one request');
      await _until(() => a.isNotEmpty && b.isNotEmpty);
      expect(a.single, ['current line=it-Lazio-Rome_60']);
      server.push('line=it-Lazio-Rome_60', ['moved']);
      await _until(() => a.length == 2);
      expect(a.last, ['moved']);

      subA.cancel();
      await server.waitForTopics({'bbox=1,2,3,4'});
      server.push('line=it-Lazio-Rome_60', ['ignored']);
      server.push('bbox=1,2,3,4', ['area']);
      await _until(() => b.length == 2);
      expect(a, hasLength(2), reason: 'unsubscribed: no more data');
    });

    test('a second subscriber to a followed topic gets the last state at once', () async {
      final first = <Object?>[], second = <Object?>[];
      live.subscribe('line=it-Lazio-Rome_60', first.add);
      await _until(() => first.isNotEmpty);
      live.subscribe('line=it-Lazio-Rome_60', second.add);
      await _until(() => second.isNotEmpty);
      expect(second.single, ['current line=it-Lazio-Rome_60']);
      expect(server.posts, hasLength(1), reason: 'already followed: nothing to tell Tramite');
    });

    test('after a dropped connection everything is subscribed again', () async {
      final got = <Object?>[];
      live.subscribe('line=it-Lazio-Rome_60', got.add);
      await _until(() => got.isNotEmpty);
      await server.dropStreams();
      await _until(() => server.streams == 2 && server.topics.contains('line=it-Lazio-Rome_60'),
          timeout: const Duration(seconds: 10));
      await _until(() => got.length == 2);
    });
  });
}

Future<void> _until(bool Function() ok, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// A minimal Tramite stream server: GET /v1/stream (hello, then pushes),
/// POST /v1/stream/{id}/topics (current state of each added topic).
class _FakeTramite {
  _FakeTramite._(this._server);
  final HttpServer _server;
  final Set<String> topics = {};
  final List<Map<String, dynamic>> posts = [];
  final List<HttpResponse> _open = [];
  int streams = 0;

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<_FakeTramite> start() async {
    final f = _FakeTramite._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    f._server.listen(f._handle);
    return f;
  }

  Future<void> _handle(HttpRequest req) async {
    if (req.method == 'GET' && req.uri.path == '/v1/stream') {
      streams++;
      topics.clear();
      final res = req.response
        ..headers.contentType = ContentType('text', 'event-stream')
        ..bufferOutput = false;
      _open.add(res);
      res.write('event: hello\ndata: {"id":"s$streams"}\n\n'); // unbuffered: sent now
      return;
    }
    if (req.method == 'POST' && req.uri.path == '/v1/stream/s$streams/topics') {
      final body = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
      posts.add(body);
      topics.removeAll((body['remove'] as List).cast<String>());
      final added = (body['add'] as List).cast<String>();
      topics.addAll(added);
      req.response.statusCode = 204;
      await req.response.close();
      for (final t in added) {
        push(t, ['current $t']);
      }
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }

  void push(String topic, Object data) {
    final res = _open.lastOrNull;
    if (res == null || !topics.contains(topic)) return;
    res.write('event: x\ndata: ${jsonEncode({'topic': topic, 'data': data})}\n\n');
  }

  Future<void> waitForTopics(Set<String> want) => _until(() => topics.length == want.length && topics.containsAll(want));

  Future<void> dropStreams() async {
    for (final r in _open) {
      await r.close();
    }
    _open.clear();
  }

  Future<void> close() async {
    await dropStreams();
    await _server.close(force: true);
  }
}
