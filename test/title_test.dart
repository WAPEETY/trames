import 'package:flutter_test/flutter_test.dart';
import 'package:roma_transit/sheet_widgets.dart';

void main() {
  test('title-cases Rome stop names', () {
    expect(titleCase('TERMINI (MA-MB-FS)'), 'Termini (MA-MB-FS)');
    expect(titleCase('PRENESTINA/MANFREDONIA'), 'Prenestina/Manfredonia');
    expect(titleCase('OJETTI/PRIMOLI'), 'Ojetti/Primoli');
    expect(titleCase('PIAZZA DI SPAGNA'), 'Piazza di Spagna');
    expect(titleCase("V.LE DELL'UMANESIMO"), "V.Le Dell'umanesimo");
    expect(titleCase('Colosseo'), 'Colosseo');
  });
}
