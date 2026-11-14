import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;

import 'backend/cities.dart' show kTramiteUrl;
import 'backend/config.dart';
import 'l10n.dart';
import 'settings.dart';
import 'sheet_widgets.dart';

/// Settings: how much you like walking, speed vs. fewer changes, and (under
/// Advanced) which MOTIS and Tramite servers to use.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final _motis = TextEditingController(text: appSettings.motisUrl);
  late final _tramite = TextEditingController(text: appSettings.tramiteUrl);
  bool _checking = false;
  String? _serverError;

  @override
  void initState() {
    super.initState();
    appSettings.addListener(_changed);
    _motis.addListener(_changed);
    _tramite.addListener(_changed);
  }

  @override
  void dispose() {
    appSettings.removeListener(_changed);
    _motis.dispose();
    _tramite.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  static String _clean(String url) => url.trim().replaceAll(RegExp(r'/+$'), '');

  bool get _serversEdited =>
      _clean(_motis.text) != appSettings.motisUrl || _clean(_tramite.text) != appSettings.tramiteUrl;

  /// Both servers must answer before switching: a typo would leave the app
  /// with no journeys or no live data.
  Future<void> _saveServers() async {
    final l = context.l10n;
    final motis = _clean(_motis.text), tramite = _clean(_tramite.text);
    setState(() {
      _checking = true;
      _serverError = null;
    });
    final ok = await Future.wait([
      motis == appSettings.motisUrl ? Future.value(true) : checkMotis(motis),
      tramite == appSettings.tramiteUrl ? Future.value(true) : checkTramite(tramite),
    ]);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _serverError = !ok[0]
          ? l.settingsServerUnreachable('MOTIS')
          : !ok[1]
              ? l.settingsServerUnreachable('Tramite')
              : null;
    });
    if (_serverError != null) return;
    appSettings.setServers(motis: motis, tramite: tramite);
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.settingsServersSaved)));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final walk = appSettings.walkLiking;
    final prefer = appSettings.routePreference;
    return Scaffold(
      body: CustomScrollView(slivers: [
        SliverAppBar.large(title: Text(l.settingsTitle)),
        SliverToBoxAdapter(child: SheetSectionHeader(l.settingsJourneys)),

        // I like walking: three-way toggle, what it means below.
        SliverToBoxAdapter(
          child: _Card(children: [
            Text(l.settingsWalkTitle, style: emphasized(context).titleMedium.copyWith(color: cs.onSurface)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: M3ESegmentedButton<WalkLiking>(
                segments: [
                  M3ESegment(value: WalkLiking.notAtAll, label: l.walkNotAtAll),
                  M3ESegment(value: WalkLiking.aBit, label: l.walkABit),
                  M3ESegment(value: WalkLiking.aLot, label: l.walkALot),
                ],
                selected: {walk},
                showSelectedIcon: false,
                onSelectionChanged: (s) {
                  HapticFeedback.selectionClick();
                  appSettings.walkLiking = s.first;
                },
              ),
            ),
            const SizedBox(height: 10),
            Text(
              switch (walk.maxRideWalk) {
                final cap? => l.walkLimitDescription(cap.inMinutes),
                null => l.walkALotDescription,
              },
              style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ]),
        ),

        // I prefer: three choices, each with what it trades.
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 20, 24, 8),
            child: Text(l.settingsPreferTitle, style: emphasized(context).titleMedium.copyWith(color: cs.onSurface)),
          ),
        ),
        SliverToBoxAdapter(
          child: M3EList(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: RoutePreference.values.length,
            itemBuilder: (_, i) {
              final p = RoutePreference.values[i];
              return Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 20, 14),
                child: Row(children: [
                  M3ERadio<RoutePreference>(
                    value: p,
                    groupValue: prefer,
                    onChanged: (v) => appSettings.routePreference = v,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        switch (p) {
                          RoutePreference.fastest => l.preferFastest,
                          RoutePreference.balanced => l.preferBalanced,
                          RoutePreference.fewerChanges => l.preferFewerChanges,
                        },
                        style: emphasized(context).titleSmall.copyWith(color: cs.onSurface),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l.preferDescription(p.changeFloor.inMinutes, (p.changeShare * 100).round()),
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ]),
                  ),
                ]),
              );
            },
            onTap: (i) {
              HapticFeedback.selectionClick();
              appSettings.routePreference = RoutePreference.values[i];
            },
          ),
        ),

        // Advanced: the servers.
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
            child: Card.filled(
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                leading: const Icon(Icons.dns_rounded),
                title: Text(l.settingsAdvanced, style: emphasized(context).titleMedium.copyWith(color: cs.onSurface)),
                shape: const Border(),
                collapsedShape: const Border(),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  _ServerField(
                    controller: _motis,
                    label: l.motisServer,
                    explain: l.motisExplain,
                    defaultUrl: kMotisUrl,
                  ),
                  const SizedBox(height: 16),
                  _ServerField(
                    controller: _tramite,
                    label: l.tramiteServer,
                    explain: l.tramiteExplain,
                    defaultUrl: kTramiteUrl,
                  ),
                  if (_serverError != null) ...[
                    const SizedBox(height: 12),
                    Text(_serverError!, style: tt.bodyMedium?.copyWith(color: cs.error)),
                  ],
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: M3EButton(
                      label: Text(_checking ? l.settingsChecking : l.settingsSave),
                      onPressed: _serversEdited && !_checking ? _saveServers : null,
                      enabled: _serversEdited && !_checking,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(child: SizedBox(height: 32 + MediaQuery.paddingOf(context).bottom)),
      ]),
    );
  }
}

/// A rounded surface card holding one setting.
class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Card.filled(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
          ),
        ),
      );
}

/// A server address, what the server is for, and a reset to the default.
class _ServerField extends StatelessWidget {
  const _ServerField({required this.controller, required this.label, required this.explain, required this.defaultUrl});
  final TextEditingController controller;
  final String label;
  final String explain;
  final String defaultUrl;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return TextField(
      controller: controller,
      keyboardType: TextInputType.url,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: label,
        helperText: explain,
        helperMaxLines: 3,
        border: const OutlineInputBorder(),
        suffixIcon: controller.text.trim() == defaultUrl
            ? null
            : IconButton(
                icon: const Icon(Icons.restart_alt_rounded),
                tooltip: l.settingsReset,
                onPressed: () => controller.text = defaultUrl,
              ),
      ),
    );
  }
}
