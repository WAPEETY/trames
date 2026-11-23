import 'package:flutter/services.dart' show HapticFeedback;
import 'package:intl/intl.dart' show DateFormat;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;

import 'backend/models.dart' show PlanTime;
import 'l10n.dart';

export 'backend/models.dart' show PlanTime;

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime _toMinute(DateTime d) => DateTime(d.year, d.month, d.day, d.hour, d.minute);

/// Calendar days from [a] to [b], unaffected by daylight saving.
int _daysBetween(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

/// How far ahead a journey can be planned.
const kPlanDaysAhead = 90;

/// "today", "tomorrow" or a short date ("mer 25 nov"), lower case first.
String _dayName(BuildContext context, DateTime day) {
  final l = context.l10n;
  final diff = _daysBetween(DateTime.now(), day);
  if (diff == 0) return l.dayToday;
  if (diff == 1) return l.dayTomorrow;
  return DateFormat.MMMEd(Localizations.localeOf(context).toLanguageTag()).format(day);
}

String _capitalized(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

bool _use24h(BuildContext context) {
  if (MediaQuery.alwaysUse24HourFormatOf(context)) return true;
  final f = MaterialLocalizations.of(context).timeOfDayFormat();
  return f == TimeOfDayFormat.HH_colon_mm || f == TimeOfDayFormat.HH_dot_mm || f == TimeOfDayFormat.frenchCanadian;
}

/// The row's text: "Parti ora", "Arriva entro le 12:46",
/// "Parti mer 25 nov alle 12:46".
String planTimeLabel(BuildContext context, PlanTime p) {
  final l = context.l10n;
  final time = p.time;
  if (time == null) return l.leaveNow;
  final hm = MaterialLocalizations.of(context)
      .formatTimeOfDay(TimeOfDay.fromDateTime(time), alwaysUse24HourFormat: _use24h(context));
  final isToday = _dateOnly(time) == _dateOnly(DateTime.now());
  if (isToday) return p.arriveBy ? l.arriveByTime(hm) : l.leaveAt(hm);
  final day = _dayName(context, time);
  return p.arriveBy ? l.arriveOnBy(day, hm) : l.leaveOnAt(day, hm);
}

/// The collapsed bar's chip: null for "now", else "14:59",
/// "entro 14:59", "domani 14:59", "entro mer 25 14:59". The month is added
/// only past a month from today, where the weekday and number repeat.
String? planTimeShort(BuildContext context, PlanTime p) {
  final time = p.time;
  if (time == null) return null;
  final l = context.l10n;
  final hm = MaterialLocalizations.of(context)
      .formatTimeOfDay(TimeOfDay.fromDateTime(time), alwaysUse24HourFormat: _use24h(context));
  final days = _daysBetween(DateTime.now(), time);
  final locale = Localizations.localeOf(context).toLanguageTag();
  final day = switch (days) {
    0 => null,
    1 => l.dayTomorrow,
    _ when days > 0 && days < 28 => DateFormat('EEE d', locale).format(time),
    _ => DateFormat.MMMEd(locale).format(time),
  };
  final when = day == null ? hm : '$day $hm';
  return p.arriveBy ? l.chipBy(when) : when;
}

/// Departure / arrival, time on wheels, and the day.
///
/// Completes with the new choice, or null when cancelled. "Now", or a time
/// that is not ahead of now when confirmed, completes with a [PlanTime]
/// whose time is null.
Future<PlanTime?> showPlanTimeDialog(BuildContext context, PlanTime current) {
  return M3EDialog.show<PlanTime>(context, dialog: _PlanTimeDialog(current));
}

class _PlanTimeDialog extends StatefulWidget {
  const _PlanTimeDialog(this.initial);

  final PlanTime initial;

  @override
  State<_PlanTimeDialog> createState() => _PlanTimeDialogState();
}

/// The hour wheel is a timeline: slot 0 is the current hour today, then on
/// hour by hour across midnight up to the last day that can be planned.
/// Nothing before now can be picked, or even seen.
class _PlanTimeDialogState extends State<_PlanTimeDialog> {
  /// Now, to the minute, when the dialog opened.
  final DateTime _origin = _toMinute(DateTime.now());

  late bool arriveBy = widget.initial.arriveBy;
  late int slot;
  late int minute;

  /// +1 when the day label moved forward, -1 back (its slide direction).
  int _dayStep = 1;

  late final FixedExtentScrollController _hours;

  int get _slotCount => 24 - _origin.hour + kPlanDaysAhead * 24;

  /// Start of the hour at [s] (wall clock: DateTime normalises hour 25).
  DateTime _slotTime(int s) => DateTime(_origin.year, _origin.month, _origin.day, _origin.hour + s);

  int _slotOf(DateTime t) => _daysBetween(_origin, t) * 24 + t.hour - _origin.hour;

  DateTime get _chosen => _slotTime(slot).add(Duration(minutes: minute));

  @override
  void initState() {
    super.initState();
    final t = widget.initial.time;
    if (t == null || !t.isAfter(_origin)) {
      slot = 0;
      minute = _origin.minute;
    } else {
      slot = _slotOf(t).clamp(0, _slotCount - 1);
      minute = t.minute;
    }
    _hours = FixedExtentScrollController(initialItem: slot);
  }

  @override
  void dispose() {
    _hours.dispose();
    super.dispose();
  }

  void _setSlot(int s) {
    final before = _slotTime(slot), after = _slotTime(s);
    final days = _daysBetween(before, after);
    setState(() {
      slot = s;
      // Back on the current hour: no minute before now.
      if (s == 0 && minute < _origin.minute) minute = _origin.minute;
      if (days != 0) _dayStep = days.sign;
    });
    if (days != 0) HapticFeedback.selectionClick();
  }

  Future<void> _changeDay() async {
    final picked = await M3EDatePicker.show(
      context,
      initialDate: _slotTime(slot),
      firstDate: _dateOnly(_origin),
      lastDate: _dateOnly(_origin).add(const Duration(days: kPlanDaysAhead)),
    );
    if (picked == null || !mounted) return;
    // Same hour on the picked day; today, not before now.
    final hour = _slotTime(slot).hour;
    final target = _slotOf(DateTime(picked.year, picked.month, picked.day, hour)).clamp(0, _slotCount - 1);
    _hours.jumpToItem(target);
    _setSlot(target);
  }

  void _confirm() {
    final t = _chosen;
    // Not ahead of now (it may have passed while the dialog was open): as if
    // no time had been set.
    Navigator.of(context).pop(
      t.isAfter(_toMinute(DateTime.now())) ? PlanTime(time: t, arriveBy: arriveBy) : const PlanTime(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final day = _dateOnly(_slotTime(slot));
    return M3EDialog(
      title: l.planTimeTitle,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        M3ESegmentedButton<bool>(
          segments: [
            M3ESegment(value: false, label: l.planDepart),
            M3ESegment(value: true, label: l.planArrive),
          ],
          selected: {arriveBy},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => arriveBy = s.first),
        ),
        const SizedBox(height: 16),
        _wheels(context),
        const SizedBox(height: 16),
        Row(children: [
          const SizedBox(width: 4),
          Icon(Icons.calendar_today_rounded, size: 20, color: cs.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: ClipRect(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (current, previous) =>
                    Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
                // Forward: the new day comes in from the right, the old one
                // leaves to the left; back, the other way round.
                transitionBuilder: (child, a) {
                  final incoming = child.key == ValueKey(day);
                  final from = Offset(incoming ? _dayStep.toDouble() : -_dayStep.toDouble(), 0);
                  return SlideTransition(
                    position: Tween(begin: from, end: Offset.zero).animate(a),
                    child: FadeTransition(opacity: a, child: child),
                  );
                },
                child: Text(
                  _capitalized(_dayName(context, day)),
                  key: ValueKey(day),
                  style: text.bodyLarge?.copyWith(color: cs.onSurface),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          M3EButton(style: M3EButtonStyle.text, label: Text(l.changeDay), onPressed: _changeDay),
        ]),
      ]),
      leadingAction: M3EButton(
        style: M3EButtonStyle.text,
        label: Text(l.resetToNow),
        onPressed: () => Navigator.of(context).pop(const PlanTime()),
      ),
      actions: [
        M3EButton(style: M3EButtonStyle.text, label: Text(l.cancel), onPressed: () => Navigator.of(context).pop()),
        M3EButton(label: Text(l.setAction), onPressed: _confirm),
      ],
    );
  }

  /// Hour (timeline) and minute wheels over one highlighted band. 12-hour
  /// locales read "1 PM" on the hour wheel.
  Widget _wheels(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final loc = MaterialLocalizations.of(context);
    final use24h = _use24h(context);
    String two(int n) => n.toString().padLeft(2, '0');
    String hourLabel(int s) {
      final h = _slotTime(s).hour;
      if (use24h) return two(h);
      return '${h % 12 == 0 ? 12 : h % 12} ${h < 12 ? loc.anteMeridiemAbbreviation : loc.postMeridiemAbbreviation}';
    }

    final nowHour = slot == 0;
    return SizedBox(
      height: _itemExtent * 3,
      child: Stack(alignment: Alignment.center, children: [
        Container(
          height: _itemExtent,
          decoration: BoxDecoration(
            color: cs.secondaryContainer,
            borderRadius: BorderRadius.circular(_itemExtent / 2),
          ),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _Wheel(
            controller: _hours,
            width: use24h ? 72 : 112,
            count: _slotCount,
            selected: slot,
            looping: false,
            label: hourLabel,
            onChanged: _setSlot,
          ),
          Text(':', style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: cs.onSecondaryContainer)),
          // On the current hour only the minutes still ahead; on any other
          // hour all of them, round and round. A new wheel when that changes.
          if (nowHour)
            _Wheel(
              key: const ValueKey('now'),
              count: 60 - _origin.minute,
              selected: minute - _origin.minute,
              looping: false,
              label: (i) => two(_origin.minute + i),
              onChanged: (i) => setState(() => minute = _origin.minute + i),
            )
          else
            _Wheel(
              key: const ValueKey('any'),
              count: 60,
              selected: minute,
              label: two,
              onChanged: (i) => setState(() => minute = i),
            ),
        ]),
      ]),
    );
  }
}

const _itemExtent = 48.0;

class _Wheel extends StatefulWidget {
  const _Wheel({
    super.key,
    required this.count,
    required this.selected,
    required this.label,
    required this.onChanged,
    this.controller,
    this.looping = true,
    this.width = 72,
  });

  final int count;
  final int selected;
  final String Function(int) label;
  final ValueChanged<int> onChanged;

  /// Owned by the caller when it must move the wheel itself.
  final FixedExtentScrollController? controller;
  final bool looping;
  final double width;

  @override
  State<_Wheel> createState() => _WheelState();
}

class _WheelState extends State<_Wheel> {
  late final FixedExtentScrollController _own = FixedExtentScrollController(initialItem: widget.selected);
  FixedExtentScrollController get _c => widget.controller ?? _own;

  @override
  void dispose() {
    _own.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.headlineSmall;
    Widget item(int i) => Center(
          child: Text(
            widget.label(i),
            maxLines: 1,
            softWrap: false,
            style: style?.copyWith(
              color: i == widget.selected ? cs.onSecondaryContainer : cs.onSurfaceVariant.withValues(alpha: 0.6),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        );
    return SizedBox(
      width: widget.width,
      child: ListWheelScrollView.useDelegate(
        controller: _c,
        itemExtent: _itemExtent,
        diameterRatio: 1.6,
        physics: const FixedExtentScrollPhysics(),
        onSelectedItemChanged: (i) => widget.onChanged(widget.looping ? i % widget.count : i),
        childDelegate: widget.looping
            ? ListWheelChildLoopingListDelegate(children: [for (var i = 0; i < widget.count; i++) item(i)])
            : ListWheelChildBuilderDelegate(childCount: widget.count, builder: (_, i) => item(i)),
      ),
    );
  }
}
