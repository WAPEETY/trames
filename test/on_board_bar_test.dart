import 'package:flutter_localizations/flutter_localizations.dart' show GlobalWidgetsLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart' hide CornerRounding, RoundedPolygon;
import 'package:roma_transit/l10n/app_localizations.dart';
import 'package:roma_transit/on_board_bar.dart';

Widget _app(Widget child) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true),
      builder: (context, c) => M3ETheme(
        data: M3EThemeData.fromMaterial(Theme.of(context)),
        initialTheme: Brightness.light,
        child: c!,
      ),
      home: Scaffold(body: Stack(children: [Positioned.fill(child: child)])),
    );

void main() {
  testWidgets('on-board toolbar fits a phone, exits with the red button', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 2.75;
    addTearDown(t.view.reset);
    var left = false;
    await t.pumpWidget(_app(OnBoardBar(
        line: '341', mode: 'BUS', headsign: 'PONTE MAMMOLO (MB) PER UNA DESTINAZIONE LUNGA', onLeave: () => left = true)));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text("You're on the 341"), findsOneWidget);
    expect(find.byType(M3EShapeContainer), findsOneWidget);
    await t.tap(find.byIcon(Icons.close_rounded));
    expect(left, isTrue);
  });

  testWidgets('boarding question fits a phone, both answers work', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 2.75;
    addTearDown(t.view.reset);
    final answers = <bool>[];
    await t.pumpWidget(_app(BoardQuestionBar(
        line: '341', mode: 'BUS', onYes: () => answers.add(true), onNo: () => answers.add(false))));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await t.tap(find.text('No'));
    await t.tap(find.text('Yes'));
    expect(answers, [false, true]);
  });
}
