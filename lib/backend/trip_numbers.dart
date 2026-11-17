/// Operators whose rides passengers tell apart by number, not by line:
/// Trenitalia's trains ("REG 21087", the number on the station boards) and
/// buses ("BUS RM200"). Their rides show the trip number after the line and
/// open as that one ride, not as a line with every vehicle on it.
///
/// Feed ids as in Transitous, the prefix of trip and route ids (Tramite uses
/// the same). Fixed here until the settings page.
const kTripNumberFeeds = {'it-trenitalia'};

/// The feed of a trip, route or stop id in Transitous form
/// (`20261117_15:28_it-trenitalia_<trip>`, `it-trenitalia_<route>`).
String? feedOf(String? id) {
  if (id == null) return null;
  final rest = RegExp(r'^\d{8}_\d+:\d{2}_(.*)$').firstMatch(id)?.group(1) ?? id;
  final cut = rest.indexOf('_');
  return cut <= 0 ? null : rest.substring(0, cut);
}

/// Whether rides of [id]'s operator show their trip number (see
/// [kTripNumberFeeds]).
bool showsTripNumber(String? id) {
  final feed = feedOf(id)?.toLowerCase();
  return feed != null && kTripNumberFeeds.any((f) => f.toLowerCase() == feed);
}

/// What passengers call the ride [id] of [line]: "REG 21087" where the
/// operator shows trip numbers and the feed has one, else the line.
String rideLabel(String line, String? tripShortName, String? id) =>
    tripShortName != null && tripShortName.isNotEmpty && showsTripNumber(id) ? '$line $tripShortName' : line;
