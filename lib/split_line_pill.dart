import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;

/// A line pill split into segments by slanted "/" gaps: one segment per line
/// that can do this leg ("211 / 111 / 450").
///
/// The first segment is the line in the planned trip (full leg color, with the
/// mode icon); the others are a lighter tint of it. More than [maxShown] lines
/// end in a "+n" segment. Drawn as one shape: the full stadium is intersected
/// with a slanted band per segment, so the gaps cut cleanly through the
/// rounded ends.
class SplitLinePill extends StatelessWidget {
  const SplitLinePill({
    super.key,
    required this.lines,
    required this.icon,
    required this.color,
    this.maxShown = 3,
  });

  final List<String> lines;
  final IconData icon;
  final Color color;
  final int maxShown;

  static const _height = 28.0;
  static const _hPad = 9.0; // inner padding of each segment
  static const _gap = 2.5; // width of the "/" cut
  static const _slant = 9.0; // horizontal run of the "/" over the full height
  static const _iconSize = 16.0;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final scaler = MediaQuery.textScalerOf(context);
    final base = M3ETheme.of(context).typography.emphasized.labelLarge;

    final shown = lines.length <= maxShown ? lines : [...lines.take(maxShown - 1), '+${lines.length - maxShown + 1}'];
    final strong = color;
    final soft = Color.alphaBlend(color.withValues(alpha: 0.42), cs.surfaceContainerHighest);
    Color fgOn(Color bg) => ThemeData.estimateBrightnessForColor(bg) == Brightness.dark ? Colors.white : Colors.black;

    final segments = <_Segment>[];
    for (var i = 0; i < shown.length; i++) {
      final bg = i == 0 ? strong : soft;
      final fg = fgOn(bg);
      final label = TextPainter(
        text: TextSpan(text: shown[i], style: base.copyWith(color: fg)),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final iconPainter = i == 0
          ? (TextPainter(
              text: TextSpan(
                text: String.fromCharCode(icon.codePoint),
                style: TextStyle(fontFamily: icon.fontFamily, package: icon.fontPackage, fontSize: _iconSize, color: fg),
              ),
              textDirection: TextDirection.ltr,
            )..layout())
          : null;
      final content = label.width + (iconPainter == null ? 0 : _iconSize + 3);
      segments.add(_Segment(label, iconPainter, bg, content + 2 * _hPad));
    }

    // Lay out left to right. Each segment gets its content width plus half a
    // slant per slanted side (so text clears the "/" edges); cuts sit in the
    // middle of each gap.
    final cuts = <double>[];
    var left = 0.0;
    var width = 0.0;
    for (var i = 0; i < segments.length; i++) {
      final slantedSides = (i > 0 ? 1 : 0) + (i < segments.length - 1 ? 1 : 0);
      final right = left + segments[i].width + slantedSides * _slant / 2;
      if (i < segments.length - 1) {
        cuts.add(right + _gap / 2);
        left = right + _gap;
      } else {
        width = right;
      }
    }

    return Semantics(
      label: 'Line ${lines.join(' or ')}',
      child: CustomPaint(
        size: Size(width, _height),
        painter: _SplitPainter(segments, cuts, width),
      ),
    );
  }
}

class _Segment {
  _Segment(this.label, this.icon, this.color, this.width);
  final TextPainter label;
  final TextPainter? icon;
  final Color color;
  final double width;
}

class _SplitPainter extends CustomPainter {
  _SplitPainter(this.segments, this.cuts, this.width);
  final List<_Segment> segments;
  final List<double> cuts;
  final double width;

  static const _gap = SplitLinePill._gap;
  static const _slant = SplitLinePill._slant;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final pill = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(h / 2)));

    // x of a "/" edge at height y, for a cut centred at c, offset by d.
    double edge(double c, double d, double y) => c + d + _slant * (0.5 - y / h);

    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      final band = Path();
      final hasLeft = i > 0;
      final hasRight = i < segments.length - 1;
      final lTop = hasLeft ? edge(cuts[i - 1], _gap / 2, 0) : -1.0;
      final lBot = hasLeft ? edge(cuts[i - 1], _gap / 2, h) : -1.0;
      final rTop = hasRight ? edge(cuts[i], -_gap / 2, 0) : width + 1;
      final rBot = hasRight ? edge(cuts[i], -_gap / 2, h) : width + 1;
      band
        ..moveTo(lTop, -1)
        ..lineTo(rTop, -1)
        ..lineTo(rBot, h + 1)
        ..lineTo(lBot, h + 1)
        ..close();
      final shape = Path.combine(PathOperation.intersect, pill, band);
      canvas.drawPath(shape, Paint()..color = s.color);

      // Centre content between the edges' midpoints (at half height).
      final left = hasLeft ? cuts[i - 1] + _gap / 2 : 0.0;
      final right = hasRight ? cuts[i] - _gap / 2 : width;
      final contentW = s.label.width + (s.icon == null ? 0 : s.icon!.width + 3);
      var cx = (left + right) / 2 - contentW / 2;
      if (s.icon != null) {
        s.icon!.paint(canvas, Offset(cx, (h - s.icon!.height) / 2));
        cx += s.icon!.width + 3;
      }
      s.label.paint(canvas, Offset(cx, (h - s.label.height) / 2));
    }
  }

  @override
  bool shouldRepaint(_SplitPainter old) => old.segments != segments || old.width != width;
}
