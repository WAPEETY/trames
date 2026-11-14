import 'package:flutter/widgets.dart';

import 'l10n/app_localizations.dart';

export 'l10n/app_localizations.dart';

extension L10nContext on BuildContext {
  /// The app's strings in the current locale (lib/l10n/app_*.arb).
  AppLocalizations get l10n => AppLocalizations.of(this);
}
