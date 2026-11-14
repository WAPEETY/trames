import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;
import 'package:url_launcher/url_launcher.dart';
import 'l10n.dart';

/// Small "© OpenStreetMap" credit that sits on the map, just above the sheet.
/// Required by the ODbL (OSM) and OpenFreeMap/OpenMapTiles terms; tapping it
/// opens the full credits.
class MapCredit extends StatelessWidget {
  const MapCredit({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Align(
      alignment: Alignment.topLeft,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showAttributionSheet(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: (dark ? Colors.black : Colors.white).withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '© OpenStreetMap',
              style: TextStyle(fontSize: 11, color: dark ? Colors.white70 : Colors.black87),
            ),
          ),
        ),
      ),
    );
  }
}

List<(String, String, String)> _credits(AppLocalizations l) => [
      (l.creditOsmName, l.creditOsm, 'https://www.openstreetmap.org/copyright'),
      ('OpenMapTiles', l.creditOpenMapTiles, 'https://www.openmaptiles.org/'),
      ('OpenFreeMap', l.creditOpenFreeMap, 'https://openfreemap.org/'),
      ('Roma Mobilità', l.creditRomaMobilita, 'https://romamobilita.it/'),
      ('opentransit', l.creditOpentransit, 'https://opentransit.tech/'),
    ];

void showAttributionSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(context.l10n.creditsTitle, style: Theme.of(context).textTheme.titleLarge),
          ),
          for (final (name, what, url) in _credits(context.l10n))
            ListTile(
              title: Text(name),
              subtitle: Text(what),
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
