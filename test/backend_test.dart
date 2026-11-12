import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/motis.dart';

void main() {
  test('MOTIS trip ids reduce to the raw GTFS trip_id', () {
    expect(MotisClient.rawTripId('20261112_04:45_it-Lazio-Rome_0#1054-2'), '0#1054-2');
    expect(MotisClient.rawTripId('20261111_29:00_it-Lazio-Rome_0#4203-23'), '0#4203-23');
    expect(MotisClient.rawTripId('weird'), 'weird');
    expect(MotisClient.rawTripId(null), isNull);
  });

  test('polyline precision 6', () {
    // (38.5, -120.2) encoded at precision 6
    final p = decodePolyline('_izlhA~rlgdF', precision: 6);
    expect(p.single.latitude, closeTo(38.5, 1e-6));
    expect(p.single.longitude, closeTo(-120.2, 1e-6));
  });

  group('stop board', () {
    final stop = Stop(id: 'x_72089', name: 'S', position: const LatLng(0, 0), distanceMeters: 0);
    final t0 = DateTime(2026, 11, 12, 23, 30);
    Departure dep(int min, String trip, {bool live = false}) =>
        Departure(time: t0.add(Duration(minutes: min)), realtime: live, tripId: trip);
    BoardRow row(String line, List<Departure> next) => BoardRow(stop: stop, line: line, mode: 'BUS', headsign: 'H', next: next);

    test('a timetable departure whose bus is already running has passed', () {
      final rows = [
        row('19', [dep(0, 'gone'), dep(6, 'a', live: true), dep(14, 'notyet')]),
        row('88', [dep(5, 'ghost88')]),
      ];
      final out = dropPassedDepartures(rows, {'gone', 'a', 'ghost88'});
      expect(out.single.next.map((d) => d.tripId), ['a', 'notyet']);
    });

    test('estimated departures move to their estimate, rows stay in order', () {
      final out = boardPerDeparture(applyReturnEstimates([
        row('3', [dep(2, 'late'), dep(6, 'red'), dep(9, 'next', live: true)]),
      ], {
        'late': const ReturnEstimate(Certainty.estimated, delay: Duration(minutes: 8)),
        'red': const ReturnEstimate(Certainty.returning),
      }));
      expect(out.map((r) => r.next.single.tripId), ['red', 'next', 'late']);
      expect(out.last.next.single.time, t0.add(const Duration(minutes: 10)));
    });

    test('a single stop lists every bus, soonest first', () {
      final out = boardPerDeparture([
        row('3', [dep(2, 'p', live: true), dep(16, 'q', live: true)]),
        row('19', [dep(6, 'a', live: true)]),
      ]);
      expect(out.map((r) => '${r.line}:${r.next.single.tripId}'), ['3:p', '19:a', '3:q']);
    });
  });

  test('certainty: on its way, not departed, or timetable', () {
    Vehicle bus(String trip, int? seq) => Vehicle(
        id: trip, label: trip, tripId: trip, routeShortName: '3', position: const LatLng(0, 0),
        timestamp: DateTime(2026), stopSequence: seq);
    final live = {'moving': bus('moving', 9), 'parked': bus('parked', 1), 'unknown': bus('unknown', null)};
    Certainty c(String trip, {bool realtime = true, Map<String, Vehicle>? vehicles}) =>
        certaintyOf(realtime: realtime, tripId: trip, vehicles: vehicles ?? live);
    expect(c('moving'), Certainty.moving);
    expect(c('parked'), Certainty.waiting); // at the terminus
    expect(c('nobus'), Certainty.waiting); // forecast, no bus on the trip yet
    expect(c('unknown'), Certainty.moving); // no stop sequence: can't tell, trust it
    expect(c('moving', realtime: false), Certainty.scheduled);
    expect(certaintyOf(realtime: true, tripId: 'x', vehicles: null), Certainty.moving); // no GPS feed
  });
}
