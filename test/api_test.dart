import 'package:flutter_test/flutter_test.dart';
import 'package:roma_transit/backend/models.dart';

void main() {
  test('decodes polyline (Google reference example)', () {
    final p = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
    expect(p.length, 3);
    expect(p[0].latitude, closeTo(38.5, 1e-6));
    expect(p[0].longitude, closeTo(-120.2, 1e-6));
    expect(p[2].latitude, closeTo(43.252, 1e-6));
    expect(p[2].longitude, closeTo(-126.453, 1e-6));
  });
}
