import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;

/// Side of the cone image, in logical pixels: the bus sits at its centre
/// and the cone reaches the top edge, so its length is half of this.
const kConeImageSize = 64.0;

/// PNG of a bus's heading cone, pointing up (north; the map rotates it):
/// a soft wedge from the centre, [color] fading out towards its tip.
Future<Uint8List> busConeImage(Color color, {double pixelRatio = 3}) async {
  const size = kConeImageSize, r = size / 2, halfAngle = 34 * math.pi / 180;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(pixelRatio);
  const centre = Offset(r, r);
  final wedge = Path()
    ..moveTo(r, r)
    ..arcTo(Rect.fromCircle(center: centre, radius: r), -math.pi / 2 - halfAngle, 2 * halfAngle, false)
    ..close();
  canvas.drawPath(
    wedge,
    Paint()
      ..shader = ui.Gradient.radial(centre, r, [color.withValues(alpha: 0.55), color.withValues(alpha: 0)]),
  );
  final px = (size * pixelRatio).round();
  final image = await recorder.endRecording().toImage(px, px);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}
