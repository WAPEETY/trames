import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;

import 'backend/backend.dart';
import 'backend/delay.dart';
import 'backend/route_search.dart';
import 'live_buses.dart';
import 'split_line_pill.dart';

Color hexColor(String hex) => Color(int.parse('FF${hex.substring(1)}', radix: 16));

String hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

int minutesUntil(DateTime t) => (t.difference(DateTime.now()).inSeconds / 60).round();

String inMinutes(DateTime t) {
  final m = minutesUntil(t);
  return m <= 0 ? 'now' : 'in $m min';
}

IconData modeIcon(String mode) => switch (mode) {
      'SUBWAY' => Icons.subway_rounded,
      'TRAM' => Icons.tram_rounded,
      'RAIL' => Icons.train_rounded,
      'WALK' => Icons.directions_walk_rounded,
      _ => Icons.directions_bus_rounded,
    };

M3ETypeScale emphasized(BuildContext context) => M3ETheme.of(context).typography.emphasized;

/// Section title inside the sheet.
class SheetSectionHeader extends StatelessWidget {
  const SheetSectionHeader(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 8),
      child: Row(children: [
        Expanded(
          child: Text(title, style: emphasized(context).titleMedium.copyWith(color: cs.onSurface)),
        ),
        ?trailing,
      ]),
    );
  }
}

/// Sub-header inside the route list: "Live · 3" (green, live icon) or
/// "Scheduled · 8".
class RouteSectionLabel extends StatelessWidget {
  const RouteSectionLabel({super.key, required this.live, required this.count, this.onFoot = false});
  final bool live;
  final int count;

  /// "On foot" (walking the whole way) instead of Live / Scheduled.
  final bool onFoot;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = live && !onFoot ? liveColor(context) : cs.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 12, 24, 8),
      child: Row(children: [
        Icon(
            onFoot
                ? Icons.directions_walk_rounded
                : live
                    ? Icons.sensors_rounded
                    : Icons.schedule_rounded,
            size: 18,
            color: color),
        const SizedBox(width: 6),
        Text(onFoot ? 'On foot' : (live ? 'Live' : 'Scheduled'),
            style: emphasized(context).labelLarge.copyWith(color: color)),
        const SizedBox(width: 6),
        Text('· $count', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
      ]),
    );
  }
}

/// Centered expressive loading indicator.
class SheetLoading extends StatelessWidget {
  const SheetLoading({super.key, this.label});
  final String? label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(children: [
        const M3ELoadingIndicator(variant: M3ELoadingIndicatorVariant.contained),
        if (label != null) ...[
          const SizedBox(height: 12),
          Text(label!, style: TextStyle(color: cs.onSurfaceVariant)),
        ],
      ]),
    );
  }
}

/// Line pill: mode icon + short name on the leg color.
class LinePill extends StatelessWidget {
  const LinePill({super.key, required this.line, required this.mode, required this.color, this.large = false});
  final String line;
  final String mode;
  final Color color;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final fg = ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Colors.white : Colors.black;
    final style = (large ? emphasized(context).titleLarge : emphasized(context).labelLarge).copyWith(color: fg);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: large ? 12 : 8, vertical: large ? 6 : 4),
      decoration: ShapeDecoration(color: color, shape: const StadiumBorder()),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(modeIcon(mode), size: large ? 20 : 16, color: fg),
        const SizedBox(width: 4),
        Text(line, style: style),
      ]),
    );
  }
}

/// Big countdown used in nearby departures: "6" over "min".
class Countdown extends StatelessWidget {
  const Countdown({super.key, required this.departure});
  final Departure departure;

  @override
  Widget build(BuildContext context) {
    final level = kDelayPolicy.classify(departure.delaySeconds, live: departure.realtime);
    final m = minutesUntil(departure.time);
    return Semantics(
      label: '${m <= 0 ? 'now' : 'in $m minutes'}, ${departure.realtime ? describeDelay(departure.delaySeconds) : 'scheduled'}',
      excludeSemantics: true,
      child: LiveMinutes(
        minutes: m,
        live: departure.realtime,
        color: delayColor(context, level),
        style: emphasized(context).headlineLarge,
      ),
    );
  }
}

/// Big minute count with "min" below; a live icon sits to its left,
/// sized to the number and centered on it.
class LiveMinutes extends StatelessWidget {
  const LiveMinutes({super.key, required this.minutes, required this.live, required this.color, required this.style});
  final int minutes;
  final bool live;
  final Color color;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final numberStyle = style.copyWith(color: color, height: 1);
    final iconSize = (numberStyle.fontSize ?? 32) * 0.6;
    return Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
        if (live) ...[
          Icon(Icons.sensors_rounded, size: iconSize, color: color),
          const SizedBox(width: 4),
        ],
        Text(minutes <= 0 ? 'now' : '$minutes', style: numberStyle),
      ]),
      if (minutes > 0) Text('min', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color)),
    ]);
  }
}

/// One nearby departure: line, direction, stop, countdown.
class NearbyDepartureRow extends StatelessWidget {
  const NearbyDepartureRow({super.key, required this.row});
  final BoardRow row;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final firstMin = minutesUntil(row.next.first.time);
    final later = row.next.skip(1).map((d) => minutesUntil(d.time)).where((m) => m > firstMin).take(2).map((m) => '$m′').join(', ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(modeIcon(row.mode), size: 22, color: cs.primary),
              const SizedBox(width: 6),
              Text(row.line, style: emphasized(context).headlineSmall.copyWith(color: cs.onSurface, height: 1.1)),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              Icon(Icons.arrow_forward_rounded, size: 16, color: cs.onSurface),
              const SizedBox(width: 4),
              Flexible(
                child: Text(_title(row.headsign),
                    overflow: TextOverflow.ellipsis,
                    style: emphasized(context).titleSmall.copyWith(color: cs.onSurface)),
              ),
            ]),
            const SizedBox(height: 2),
            Text(
              '${_title(row.stop.name)} · ${row.stop.distanceMeters} m${later.isEmpty ? '' : ' · then $later'}',
              overflow: TextOverflow.ellipsis,
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ]),
        ),
        const SizedBox(width: 12),
        Countdown(departure: row.next.first),
      ]),
    );
  }
}

/// GTFS names in Rome are ALL CAPS; make them readable.
/// Rome's GTFS names are ALL CAPS ("TERMINI (MA-MB-FS)", "OJETTI/PRIMOLI").
/// Keep parenthesised codes as-is, title-case words (also after "/" or "."),
/// and lowercase short Italian particles.
const _particles = {'di', 'de', 'del', 'della', 'delle', 'dei', 'degli', 'da', 'e', 'a', 'al', 'alla', 'in'};
String _title(String s) {
  if (s != s.toUpperCase()) return s; // already mixed case
  var first = true;
  return s.replaceAllMapped(RegExp(r"\([^)]*\)|[A-Za-zÀ-ÿ']+"), (m) {
    final w = m[0]!;
    if (w.startsWith('(')) return w;
    final lower = w.toLowerCase();
    final keepLower = !first && _particles.contains(lower);
    first = false;
    return keepLower ? lower : '${lower[0].toUpperCase()}${lower.substring(1)}';
  });
}

String titleCase(String s) => _title(s);

/// Green used for "this time is live", harmonized with the app's palette.
Color liveColor(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  final base = cs.brightness == Brightness.dark ? const Color(0xFF6DD58C) : const Color(0xFF146C2E);
  return base.harmonizeWith(cs.primary);
}

/// Color of a live time by how late it is: green on time (or early), orange
/// a bit late, red very late; grey when there's no live data.
/// Light/dark tones keep text contrast on the sheet's surfaces.
Color delayColor(BuildContext context, DelayLevel level) {
  final cs = Theme.of(context).colorScheme;
  final dark = cs.brightness == Brightness.dark;
  return switch (level) {
    DelayLevel.unknown => cs.onSurfaceVariant,
    DelayLevel.onTime => liveColor(context),
    DelayLevel.minor => (dark ? const Color(0xFFFFB960) : const Color(0xFF8F4C00)).harmonizeWith(cs.primary),
    DelayLevel.major => (dark ? const Color(0xFFFF8A80) : const Color(0xFFB3261E)).harmonizeWith(cs.primary),
  };
}

/// Delay level of boarding [leg], weighed against how far away it is.
DelayLevel boardingLevel(Leg leg) {
  final until = leg.start.difference(DateTime.now());
  return kDelayPolicy.classify(leg.delaySeconds,
      reference: until.isNegative ? Duration.zero : until, live: leg.realtime);
}

/// One itinerary in the route list.
///
/// Live state is shown through color only (green on time, orange a bit
/// late, red very late; see [DelayPolicy]):
///  * every transit leg live  -> time range + arrival colored by arrival delay;
///  * first leg live          -> departure time colored by that bus's delay;
///  * otherwise               -> neutral (scheduled).
class ItineraryRow extends StatelessWidget {
  const ItineraryRow({
    super.key,
    required this.it,
    required this.colorFor,
    this.padding = const EdgeInsets.fromLTRB(20, 16, 20, 16),
    this.lineOptions,
  });
  final Itinerary it;
  final Color Function(Itinerary, Leg) colorFor;
  final EdgeInsets padding;

  /// Optional lines per transit leg (in order), planned line first, e.g.
  /// ["88", "3"] when either can do the leg: shown as a split pill.
  final List<List<String>>? lineOptions;

  List<String>? _optionsFor(int legIndex) {
    final all = lineOptions;
    if (all == null) return null;
    final k = it.legs.take(legIndex).where((l) => l.transit).length;
    return k < all.length ? all[k] : null;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final legs = it.transitLegs.toList();
    final allLive = legs.isNotEmpty && legs.every((l) => l.realtime);
    final firstLive = legs.isNotEmpty && legs.first.realtime;
    final grey = cs.onSurfaceVariant;
    final base = tt.bodyMedium?.copyWith(color: grey);
    // Departure: first vehicle's delay vs. how far away it is.
    // Arrival: final arrival delay vs. the trip's duration.
    final depColor = firstLive ? delayColor(context, boardingLevel(legs.first)) : grey;
    final arrColor = allLive
        ? delayColor(context, kDelayPolicy.classify(it.arrivalDelaySeconds, reference: it.duration))
        : grey;
    final depStyle = base?.copyWith(color: depColor, fontWeight: FontWeight.w600);
    final arrStyle = base?.copyWith(color: arrColor, fontWeight: FontWeight.w600);

    final times = Text.rich(TextSpan(children: [
      if (firstLive)
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(Icons.sensors_rounded, size: 16, color: depColor),
          ),
        ),
      TextSpan(text: hm(it.start), style: firstLive ? depStyle : base),
      TextSpan(
        text: ' – ${hm(it.end)} · ${it.duration.inMinutes} min',
        style: allLive ? arrStyle : base,
      ),
    ]));

    return Padding(
      padding: padding,
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(legs.isEmpty ? 'Walk' : 'Leave ${inMinutes(it.start)}',
                style: emphasized(context).titleMedium.copyWith(color: cs.onSurface)),
            const SizedBox(height: 2),
            times,
            const SizedBox(height: 10),
            // Wraps inside the left column, so it never runs under the arrival time.
            Wrap(spacing: 4, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (var i = 0; i < it.legs.length; i++) ...[
                if (i > 0) Icon(Icons.chevron_right_rounded, size: 18, color: cs.outline),
                if (it.legs[i].transit)
                  if (_optionsFor(i) case final opts? when opts.length > 1)
                    SplitLinePill(lines: opts, icon: modeIcon(it.legs[i].mode), color: colorFor(it, it.legs[i]))
                  else
                    LinePill(
                      line: it.legs[i].routeShortName ?? it.legs[i].mode,
                      mode: it.legs[i].mode,
                      color: colorFor(it, it.legs[i]),
                    )
                else if (it.walkOptions[i] case final buses? when buses.isNotEmpty)
                  // Walking chosen over a ride: "🚶 20 ╱ 3BUS", the buses are
                  // the swipe options for this stretch in the trip view.
                  SplitLinePill(
                    lines: ['${it.legs[i].duration.inMinutes}', ...buses],
                    icon: Icons.directions_walk_rounded,
                    color: grey,
                  )
                else
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.directions_walk_rounded, size: 18, color: grey),
                    Text('${it.legs[i].end.difference(it.legs[i].start).inMinutes}',
                        style: tt.labelMedium?.copyWith(color: grey)),
                  ]),
              ],
            ]),
          ]),
        ),
        const SizedBox(width: 16),
        Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('arrive', style: tt.labelMedium?.copyWith(color: arrColor)),
          Text(
            hm(it.end),
            style: emphasized(context).displaySmall.copyWith(color: allLive ? arrColor : cs.onSurface, height: 1.05),
          ),
        ]),
      ]),
    );
  }
}

/// Minutes until this vehicle reaches the boarding stop: green with live icon
/// when the time is live, grey when it is only predicted from the timetable.
class WaitIndicator extends StatelessWidget {
  const WaitIndicator({super.key, required this.minutes, required this.live, this.level = DelayLevel.onTime});
  final int minutes;
  final bool live;
  final DelayLevel level;

  @override
  Widget build(BuildContext context) => LiveMinutes(
        minutes: minutes,
        live: live,
        color: live ? delayColor(context, level) : Theme.of(context).colorScheme.onSurfaceVariant,
        style: emphasized(context).headlineMedium,
      );
}

/// One leg in the trip detail. [waitMinutes] is how long until the vehicle
/// reaches the boarding stop (transit legs only).
class LegRow extends StatelessWidget {
  const LegRow({super.key, required this.leg, required this.color, this.bus, this.waitMinutes});
  final Leg leg;
  final Color color;
  final TrackedBus? bus;
  final int? waitMinutes;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final mins = leg.end.difference(leg.start).inMinutes;
    // A ride's delay weighed against that ride's own duration.
    final level = kDelayPolicy.classify(leg.delaySeconds, reference: leg.duration, live: leg.realtime);
    final timeStyle =
        emphasized(context).labelLarge.copyWith(color: leg.realtime ? delayColor(context, level) : cs.onSurface);
    if (!leg.transit) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        child: Row(children: [
          SizedBox(width: 52, child: Text(hm(leg.start), style: timeStyle)),
          Icon(Icons.directions_walk_rounded, color: cs.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text('Walk ${leg.distanceMeters.round()} m · $mins min\nto ${titleCase(leg.toName)}',
                style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
          ),
        ]),
      );
    }
    final busAge = bus == null ? null : DateTime.now().difference(bus!.vehicle.timestamp).inSeconds;
    final d = leg.delaySeconds ?? 0;
    final delay = !leg.realtime
        ? null
        : d >= 60
            ? '+${(d / 60).round()} min late'
            : d <= -60
                ? '${(-d / 60).round()} min early'
                : 'on time';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(width: 52, child: Text(hm(leg.start), style: timeStyle)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              LinePill(line: leg.routeShortName ?? leg.mode, mode: leg.mode, color: color, large: true),
              const SizedBox(width: 10),
              Expanded(
                child: Text(titleCase(leg.headsign ?? ''),
                    overflow: TextOverflow.ellipsis, style: emphasized(context).titleSmall.copyWith(color: cs.onSurface)),
              ),
            ]),
            const SizedBox(height: 8),
            Text('${titleCase(leg.fromName)} → ${titleCase(leg.toName)}', style: tt.bodyMedium?.copyWith(color: cs.onSurface)),
            Text(
              [
                '${leg.intermediateStops} stops · $mins min · arrive ${hm(leg.end)}',
                ?delay,
              ].join(' · '),
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            if (bus != null || leg.realtime) ...[
              const SizedBox(height: 4),
              Text(
                bus != null ? 'bus ${bus!.vehicle.label} · GPS ${busAge}s ago' : 'locating bus…',
                style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],

          ]),
        ),
        if (waitMinutes != null) ...[
          const SizedBox(width: 12),
          WaitIndicator(minutes: waitMinutes!, live: leg.realtime, level: level),
        ],
      ]),
    );
  }
}

/// One line sequence in the route list: its best trip in full, small tags
/// (fastest / fewest changes / least walking). Later buses: open it and swipe.
class RouteGroupRow extends StatelessWidget {
  const RouteGroupRow({super.key, required this.group, required this.colorFor});
  final RouteGroup group;
  final Color Function(Itinerary, Leg) colorFor;

  /// Per transit leg: its own line first, then the other lines that can
  /// replace it (from the planner's leg alternatives).
  static List<List<String>> _lineOptions(Itinerary it) => [
        for (final leg in it.transitLegs)
          <String>{leg.routeShortName ?? leg.mode, for (final a in leg.alternatives) a.line}.toList(),
      ];

  @override
  Widget build(BuildContext context) {
    final hasTags = group.tags.isNotEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (hasTags)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: Wrap(spacing: 6, runSpacing: 6, children: [for (final t in group.tags) _RouteTagChip(t)]),
        ),
      ItineraryRow(
        it: group.best,
        colorFor: colorFor,
        lineOptions: _lineOptions(group.best),
        padding: EdgeInsets.fromLTRB(20, hasTags ? 8 : 16, 20, 16),
      ),
    ]);
  }
}

class _RouteTagChip extends StatelessWidget {
  const _RouteTagChip(this.tag);
  final RouteTag tag;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, label) = switch (tag) {
      RouteTag.fastest => (Icons.bolt_rounded, 'Fastest'),
      RouteTag.fewestChanges => (Icons.swap_horiz_rounded, 'Fewest changes'),
      RouteTag.leastWalking => (Icons.directions_walk_rounded, 'Least walking'),
      RouteTag.onFoot => (Icons.directions_walk_rounded, 'Faster on foot'),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 3, 10, 3),
      decoration: ShapeDecoration(color: cs.secondaryContainer, shape: const StadiumBorder()),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: cs.onSecondaryContainer),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSecondaryContainer)),
      ]),
    );
  }
}

