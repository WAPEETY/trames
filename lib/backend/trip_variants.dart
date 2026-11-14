import 'package:maplibre_gl/maplibre_gl.dart';

import 'backend.dart';
import 'walk_rules.dart';

/// Lets the user swap individual rides of an itinerary for one of their
/// alternatives, or for walking, and keeps the rest of the trip consistent.
///
/// Every transit leg of the base itinerary is a *slot*. A slot's *span* is the
/// ride plus the walks right before and after it. Its ride variants are the
/// original span, then the span's [Leg.alternatives] (each `[walk, ride,
/// walk]`); last, when the span is short enough, comes *walking*: one walk
/// from where the span starts to where it ends.
///
/// Rides of [WalkPolicy.hideRidesUpTo] or less are never offered. A slot whose
/// own ride is that short starts on walking (or its first other ride); with
/// neither, the itinerary is [impossible].
///
/// Composing a trip replaces each slot's span with its chosen variant:
///  * consecutive walked slots become a single walk (one street route from
///    the first span's start to the last span's end, not the pieces glued);
///  * a walk next to a walked slot is absorbed by it (the walk covers it);
///  * picking a ride again brings back that ride's own walks.
/// Walks are then re-timed around the rides: walks before the first ride end
/// when it leaves, every other walk starts when the previous ride arrives.
///
/// Alternatives and walks are computed against the *original* neighbours, so
/// mixing two swapped slots can break a connection. [choose] detects that and
/// resets the other slots to the original ride, which always fits.
///
/// Walk routes come from [walks]; routes not fetched yet are estimated and
/// listed in [missingWalks] so the caller can fetch them and [refresh].
class TripVariants {
  TripVariants(
    this.base, {
    this.walks,
    Set<int> walkSlots = const {},
    List<int>? choices,
    this.policy = kWalkPolicy,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    final now = _clock();
    for (var i = 0; i < base.legs.length; i++) {
      final leg = base.legs[i];
      if (!leg.transit) continue;
      final start = i > 0 && !base.legs[i - 1].transit ? i - 1 : i;
      final end = i + 1 < base.legs.length && !base.legs[i + 1].transit ? i + 1 : i;
      final seen = <String>{leg.tripId ?? '${leg.routeShortName}@${leg.start}'};
      final from = base.legs[start].from, to = base.legs[end].to;
      // The ride you're on can't be swapped, walked or hidden.
      final pinned = leg.onBoard;
      bool keep(Leg ride) => pinned || ride.duration > policy.hideRidesUpTo;
      _slots.add(_Slot(
        start,
        end,
        [
          if (keep(leg)) base.legs.sublist(start, end + 1),
          for (final alt in leg.alternatives)
            if (!pinned &&
                keep(alt.ride) &&
                alt.reachableFrom(now) &&
                seen.add(alt.ride.tripId ?? '${alt.line}@${alt.ride.start}'))
              alt.legs,
        ],
        walkable: !pinned && walks != null && distanceMeters(from, to) / 1000 <= policy.maxWalkKm,
        hidden: !keep(leg),
      ));
    }
    // Default per slot: the original ride; for a hidden one walking, else
    // the first other ride.
    defaults = [
      for (final slot in _slots) slot.hidden && slot.walkable ? slot.variants.length : 0,
    ];
    impossible = _slots.any((s) => s.variants.isEmpty && !s.walkable);
    _choice = [
      for (var s = 0; s < _slots.length; s++)
        walkSlots.contains(s) && _slots[s].walkable ? _slots[s].variants.length : defaults[s],
    ];
    // Given choices (e.g. a route re-planned around a late bus) win when
    // they still fit.
    if (choices != null &&
        choices.length == _slots.length &&
        [for (var s = 0; s < _slots.length; s++) choices[s] >= 0 && choices[s] < variantCount(s)].every((ok) => ok)) {
      final fallback = _choice;
      _choice = List.of(choices);
      if (!_compose()) _choice = fallback;
    }
    if (!_compose()) {
      _choice = List.of(defaults);
      if (!_compose()) {
        // A hidden ride's walk doesn't fit: try its first other ride.
        for (var s = 0; s < _slots.length; s++) {
          if (_slots[s].hidden && _slots[s].variants.isNotEmpty) _choice[s] = 0;
        }
        _compose();
      }
    }
  }

  /// Default choice per slot (the original ride, or walking / another ride
  /// for a hidden one).
  late final List<int> defaults;

  /// A hidden ride with neither walking nor another ride to replace it.
  late final bool impossible;

  /// Whether any original ride is hidden (too short to offer).
  bool get hasHidden => _slots.any((s) => s.hidden);

  /// Slots whose original ride is hidden.
  Iterable<int> get hiddenSlots => [for (var s = 0; s < _slots.length; s++) if (_slots[s].hidden) s];

  final Itinerary base;
  final WalkCache? walks;
  final WalkPolicy policy;
  final DateTime Function() _clock;
  final _slots = <_Slot>[];
  late List<int> _choice;
  late Itinerary _current;
  late List<int?> _slotOfLeg;
  var _feasible = true;
  final _missing = <String, (LatLng, LatLng)>{};

  Itinerary get current => _current;
  bool get feasible => _feasible;
  int get slotCount => _slots.length;
  int variantCount(int slot) => _slots[slot].variants.length + (_slots[slot].walkable ? 1 : 0);
  int choiceOf(int slot) => _choice[slot];

  /// Index of the walking variant of [slot], or null when it can't be walked.
  int? walkIndex(int slot) => _slots[slot].walkable ? _slots[slot].variants.length : null;
  bool isWalk(int slot, int variant) => variant == walkIndex(slot);

  /// Walk routes used in [current] that aren't fetched yet (estimated).
  Iterable<(LatLng, LatLng)> get missingWalks => _missing.values;

  /// Where walking [slot] would start and end (for fetching its route).
  (LatLng, LatLng) slotSpan(int slot) => (base.legs[_slots[slot].start].from, base.legs[_slots[slot].end].to);

  /// The original ride of [slot] and when its span starts / ends.
  Leg slotRide(int slot) => base.legs[_slots[slot].start].transit
      ? base.legs[_slots[slot].start]
      : base.legs[_slots[slot].start + 1];
  DateTime spanStart(int slot) => base.legs[_slots[slot].start].start;
  DateTime spanEnd(int slot) => base.legs[_slots[slot].end].end;

  /// Slot of a leg in [current] (rides and walks that replace a ride), or
  /// null for ordinary walks.
  int? slotOfLeg(int legIndex) => _slotOfLeg[legIndex];

  /// The ride a slot would use for a ride [variant] (for labels).
  Leg rideOf(int slot, int variant) => _slots[slot].variants[variant].firstWhere((l) => l.transit);

  /// Walking time of [slot] alone (fetched route, else estimate).
  Duration walkDurationOf(int slot) {
    final (from, to) = slotSpan(slot);
    return walks?.lookup(from, to)?.duration ?? _estimate(from, to).$1;
  }

  List<int> get choices => List.of(_choice);
  void restore(List<int> choices) {
    _choice = List.of(choices);
    _compose();
  }

  /// Re-composes with walk routes fetched since (see [missingWalks]).
  void refresh() => _compose();

  /// Selects [variant] for [slot]. Returns false when other slots had to be
  /// reset to their original ride to keep the trip feasible.
  bool choose(int slot, int variant) {
    _choice[slot] = variant.clamp(0, variantCount(slot) - 1);
    if (_compose()) return true;
    for (var s = 0; s < _choice.length; s++) {
      if (s != slot) _choice[s] = defaults[s];
    }
    _compose();
    return false;
  }

  /// Lines among [slot]'s ride variants (too-short rides already excluded).
  List<String> _rideLines(int slot) => {
        for (final v in _slots[slot].variants)
          for (final l in v)
            if (l.transit) l.routeShortName ?? l.mode,
      }.toList();

  static (Duration, double) _estimate(LatLng from, LatLng to) {
    final meters = distanceMeters(from, to) * 1.3; // streets aren't straight
    return (Duration(seconds: (meters / (kWalkingSpeedKmh / 3.6)).round()), meters);
  }

  Leg _walk(LatLng from, LatLng to, String fromName, String toName, DateTime start) {
    final route = walks?.lookup(from, to);
    if (route == null) _missing[walkKey(from, to)] = (from, to);
    final (estimate, estMeters) = _estimate(from, to);
    final duration = route?.duration ?? estimate;
    return Leg(
      mode: 'WALK',
      transit: false,
      start: start,
      end: start.add(duration),
      fromName: fromName,
      toName: toName,
      from: from,
      to: to,
      points: route?.points ?? [from, to],
      distanceMeters: route?.distanceMeters ?? estMeters,
    );
  }

  /// Builds [current]; returns whether every connection still works.
  bool _compose() {
    _missing.clear();
    final legs = <Leg>[];
    final slotOf = <int?>[];
    var i = 0;
    var s = 0;
    var replaceable = true;
    while (s < _slots.length) {
      final slot = _slots[s];
      for (; i < slot.start; i++) {
        legs.add(base.legs[i]);
        slotOf.add(null);
      }
      if (isWalk(s, _choice[s])) {
        // Extend over following walked slots whose spans touch: one walk.
        var e = s;
        while (e + 1 < _slots.length && isWalk(e + 1, _choice[e + 1]) && _slots[e + 1].start <= _slots[e].end + 1) {
          e++;
        }
        final first = base.legs[_slots[s].start], last = base.legs[_slots[e].end];
        legs.add(_walk(first.from, last.to, first.fromName, last.toName, first.start));
        slotOf.add(s);
        i = _slots[e].end + 1;
        s = e + 1;
        continue;
      }
      if (slot.variants.isEmpty) {
        // Hidden ride with nothing to replace it (see [impossible]).
        replaceable = false;
        for (; i <= slot.end; i++) {
          legs.add(base.legs[i]);
          slotOf.add(base.legs[i].transit ? s : null);
        }
        s++;
        continue;
      }
      for (final l in slot.variants[_choice[s]]) {
        if (!l.transit && l.duration.inSeconds <= 0 && l.distanceMeters < 1) continue; // empty footpath
        legs.add(l);
        slotOf.add(l.transit ? s : null);
      }
      i = slot.end + 1;
      s++;
    }
    for (; i < base.legs.length; i++) {
      legs.add(base.legs[i]);
      slotOf.add(null);
    }

    // Two walks in a row: a walk that replaces a ride covers its neighbour
    // (its span included it); otherwise both describe the same transfer and
    // the longer one is kept.
    for (var j = legs.length - 1; j > 0; j--) {
      if (!legs[j].transit && !legs[j - 1].transit) {
        final a = j - 1, b = j;
        final keepB = slotOf[b] != null && slotOf[a] == null
            ? true
            : slotOf[a] != null && slotOf[b] == null
                ? false
                : legs[b].duration >= legs[a].duration;
        if (keepB) {
          legs[a] = legs[b];
          slotOf[a] = slotOf[b];
        }
        legs.removeAt(b);
        slotOf.removeAt(b);
      }
    }

    // Re-time walks around the rides and check every connection.
    var feasible = replaceable;
    final firstRide = legs.indexWhere((l) => l.transit);
    final now = _clock();
    for (var j = 0; j < legs.length; j++) {
      final l = legs[j];
      if (l.transit) continue;
      if (firstRide >= 0 && j < firstRide) {
        // Walk(s) before the first ride: end exactly when it leaves.
        legs[j] = l.movedTo(legs[j + 1].start.subtract(l.duration));
      } else if (j > 0) {
        legs[j] = l.movedTo(legs[j - 1].end);
      } else {
        legs[j] = l.movedTo(now); // walking the whole way: leave now
      }
    }
    for (var j = 1; j < legs.length; j++) {
      if (legs[j].transit && legs[j - 1].end.isAfter(legs[j].start)) feasible = false;
    }
    // A walk that replaces the first ride can't start in the past.
    if (legs.isNotEmpty && slotOf[0] != null && !legs[0].transit &&
        legs[0].start.isBefore(now.subtract(const Duration(minutes: 1)))) {
      feasible = false;
    }

    _current = Itinerary(
      start: legs.first.start,
      end: legs.last.end,
      legs: legs,
      transfers: (legs.where((l) => l.transit).length - 1).clamp(0, 99),
      base: base,
      walkSlots: {for (var k = 0; k < _slots.length; k++) if (isWalk(k, _choice[k])) k},
      rideChoices: List.of(_choice),
      walkOptions: {
        for (var j = 0; j < legs.length; j++)
          if (!legs[j].transit && slotOf[j] != null && _rideLines(slotOf[j]!).isNotEmpty) j: _rideLines(slotOf[j]!),
      },
    );
    _slotOfLeg = slotOf;
    _feasible = feasible;
    return feasible;
  }
}

class _Slot {
  _Slot(this.start, this.end, this.variants, {required this.walkable, required this.hidden});

  /// Index range in the base itinerary that a variant replaces (inclusive).
  final int start;
  final int end;

  /// Ride variants (0 = original); walking, when [walkable], comes after.
  final List<List<Leg>> variants;
  final bool walkable;

  /// The original ride is too short to offer (not among [variants]).
  final bool hidden;
}
