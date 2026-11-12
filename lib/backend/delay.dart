/// How late (or early) a live vehicle is, judged against how long the thing
/// it affects lasts: 4 minutes wreck a 10-minute trip but barely matter on a
/// 70-minute one. A pure percentage breaks at the extremes, so the limits are
/// a percentage of the reference duration with a floor and a cap.
enum DelayLevel {
  /// No live data, or a value too implausible to trust.
  unknown,
  onTime,
  minor,
  major,
}

class DelayPolicy {
  const DelayPolicy({
    this.onTimeFloor = const Duration(minutes: 5),
    this.onTimeShare = 0.20,
    this.onTimeCap = const Duration(minutes: 15),
    this.minorFloor = const Duration(minutes: 10),
    this.minorShare = 0.40,
    this.minorCap = const Duration(minutes: 30),
    this.plausibleEarliest = const Duration(minutes: -10),
    this.plausibleLatest = const Duration(minutes: 90),
  });

  /// Late up to max(floor, share × reference), capped, is still on time.
  final Duration onTimeFloor;
  final double onTimeShare;
  final Duration onTimeCap;

  /// Late up to max(floor, share × reference), capped, is a minor delay.
  final Duration minorFloor;
  final double minorShare;
  final Duration minorCap;

  /// Outside this range a delay is treated as a feed error and ignored
  /// (Rome's feed occasionally reports values a whole day off).
  final Duration plausibleEarliest;
  final Duration plausibleLatest;

  /// [delaySeconds] = live minus scheduled (negative = early). [reference] is
  /// the duration the delay is weighed against; without it only the floors
  /// apply. Non-live data is always [DelayLevel.unknown].
  DelayLevel classify(int? delaySeconds, {Duration? reference, bool live = true}) {
    if (!live || delaySeconds == null) return DelayLevel.unknown;
    final d = Duration(seconds: delaySeconds);
    if (d < plausibleEarliest || d > plausibleLatest) return DelayLevel.unknown;

    // Early is never a problem worth flagging: the live countdown already
    // tells you when to be at the stop.
    if (d.isNegative) return DelayLevel.onTime;

    final ref = reference ?? Duration.zero;
    Duration share(double f) => Duration(seconds: (ref.inSeconds * f).round());
    Duration max(Duration a, Duration b) => a > b ? a : b;
    Duration min(Duration a, Duration b) => a < b ? a : b;

    final onTimeLimit = min(onTimeCap, max(onTimeFloor, share(onTimeShare)));
    final minorLimit = max(onTimeLimit, min(minorCap, max(minorFloor, share(minorShare))));
    if (d <= onTimeLimit) return DelayLevel.onTime;
    if (d <= minorLimit) return DelayLevel.minor;
    return DelayLevel.major;
  }
}

const kDelayPolicy = DelayPolicy();

/// "3 min late", "1 min early", "on time" (for screen readers and labels).
String describeDelay(int? delaySeconds) {
  if (delaySeconds == null) return 'scheduled';
  final m = (delaySeconds / 60).round();
  if (m == 0) return 'on time';
  return m > 0 ? '$m min late' : '${-m} min early';
}
