import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;

import 'home_page.dart';

/// Fallback seed when the device has no wallpaper colors (Material You).
const kSeed = Color(0xFFD81B60);

void main() => runApp(const TransitApp());

class TransitApp extends StatelessWidget {
  const TransitApp({super.key});

  /// One ColorScheme per brightness, shared by Material and M3E widgets so the
  /// two never disagree (M3ETheme's own dynamicColoring only recolors M3E).
  static ThemeData _theme(ColorScheme? dynamic, Brightness b) {
    final scheme = dynamic?.harmonized() ??
        ColorScheme.fromSeed(
          seedColor: kSeed,
          brightness: b,
          dynamicSchemeVariant: DynamicSchemeVariant.expressive,
        );
    return ThemeData(colorScheme: scheme, useMaterial3: true);
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (light, dark) => MaterialApp(
        title: 'Trames',
        debugShowCheckedModeBanner: false,
        theme: _theme(light, Brightness.light),
        darkTheme: _theme(dark, Brightness.dark),
        // M3E tokens (type scale, shapes, springs) derived from the active
        // Material theme. initialTheme: light means "use this data as-is";
        // the data itself is already light or dark.
        builder: (context, child) => M3ETheme(
          data: M3EThemeData.fromMaterial(Theme.of(context)),
          initialTheme: Brightness.light,
          child: child!,
        ),
        home: const HomePage(),
      ),
    );
  }
}
