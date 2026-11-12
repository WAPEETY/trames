import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/backend/returning.dart';

final _t0 = DateTime(2026, 11, 13, 10);
DateTime _m(int min) => _t0.add(Duration(minutes: min));
const _terminus = LatLng(41.9, 12.5);
const _elsewhere = LatLng(41.95, 12.55); // the other end of the line
const _origin = TripOrigin(stopId: 'T', position: _terminus);

class _Source implements ReturnSource {
  _Source(this.runs, this.ends);
  final List<TerminusRun> runs;
  final Map<String, TripEnd> ends; // by vehicle trip id
  int endCalls = 0;

  @override
  Future<List<TerminusRun>> departuresFrom(String stopId) async => runs;

  @override
  Future<TripEnd?> tripEnd(Vehicle v) async {
    endCalls++;
    return ends[v.tripId];
  }
}

TerminusRun _run(String trip, int min, {bool live = false}) =>
    TerminusRun(tripId: trip, line: '3', scheduled: _m(min), realtime: live, directionId: 0);

Vehicle _bus(String trip, {int dir = 1, int seq = 10, String line = '3'}) => Vehicle(
    id: trip, label: trip, tripId: trip, routeShortName: line, position: _elsewhere,
    timestamp: _t0, directionId: dir, stopSequence: seq);

TripEnd _end(int min, [LatLng at = _terminus]) => TripEnd(position: at, time: _m(min));

void main() {
  Future<Map<String, ReturnEstimate>> run(_Source s, List<Vehicle> buses) => ReturnEstimator(s, clock: () => _t0)
      .estimate([const ReturnQuery('3', _origin)], {for (final v in buses) v.tripId!: v});

  test('in time: red; too late: purple with the delay; no bus left: timetable', () async {
    final s = _Source([_run('b', 10), _run('c', 20), _run('d', 30)], {'x': _end(5), 'y': _end(25)});
    final r = await run(s, [_bus('x', seq: 30), _bus('y', seq: 12)]);
    expect(r['b']!.certainty, Certainty.returning); // ready 10:08, leaves 10:10
    expect(r['c']!.certainty, Certainty.estimated); // ready 10:28 instead of 10:20
    expect(r['c']!.delay, const Duration(minutes: 8));
    expect(r.containsKey('d'), isFalse);
  });

  test('a departure with its own bus, or a live one, uses up no / one bus', () async {
    // a: bus parked on it. b: live, no bus yet -> takes x. c: gets y.
    final s = _Source([_run('a', 2, live: true), _run('b', 10, live: true), _run('c', 20)], {'x': _end(5), 'y': _end(12)});
    final r = await run(s, [_bus('a', dir: 0, seq: 1), _bus('x', seq: 30), _bus('y', seq: 20)]);
    expect(r.keys, ['c']);
    expect(r['c']!.certainty, Certainty.returning); // y ready 10:15
  });

  test('buses ending elsewhere, same direction or other lines do not count', () async {
    final s = _Source([_run('b', 10)], {'x': _end(5, _elsewhere), 'z': _end(5), 'w': _end(5)});
    final r = await run(s, [_bus('x'), _bus('z', dir: 0), _bus('w', line: '19')]);
    expect(r, isEmpty);
  });

  test('nothing to estimate: no trip requests', () async {
    final s = _Source([_run('b', 10, live: true)], {'x': _end(5)});
    expect(await run(s, [_bus('b', dir: 0, seq: 1), _bus('x')]), isEmpty);
    expect(s.endCalls, 0);
  });
}
