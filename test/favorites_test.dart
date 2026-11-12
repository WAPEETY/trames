import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:roma_transit/backend/backend.dart';
import 'package:roma_transit/favorites.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() => SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty());

  const stop = Place(
    name: 'Nomentana/Regina Margherita',
    position: LatLng(41.9145, 12.5125),
    kind: PlaceKind.stop,
    stopId: 'it-Lazio-Rome_71502',
  );
  const colosseo = Place(name: 'Colosseo', subtitle: 'Place · Roma', position: LatLng(41.8902, 12.4922));

  test('toggle, split into stops and destinations, survive a restart', () async {
    final store = FavoritesStore();
    await store.load();
    await store.toggle(stop);
    await store.toggle(colosseo);
    expect(store.isFavorite(stop), isTrue);
    expect(store.stops.single.stopId, 'it-Lazio-Rome_71502');
    expect(store.destinations.single.name, 'Colosseo');

    final reopened = FavoritesStore(); // same device storage, new app run
    await reopened.load();
    expect(reopened.stops.single.kind, PlaceKind.stop);
    expect(reopened.destinations.single.position.latitude, closeTo(41.8902, 1e-9));

    await reopened.toggle(stop); // tap the star again: removed
    expect(reopened.isFavorite(stop), isFalse);
    final third = FavoritesStore();
    await third.load();
    expect(third.stops, isEmpty);
  });

  test('stop code from backend id', () {
    expect(stopCodeFromId('it-Lazio-Rome_71502'), '71502');
    expect(stopCodeFromId('roma:71502'), '71502');
    expect(Stop(id: 'it-Lazio-Rome_72590', name: 'x', position: const LatLng(0, 0), distanceMeters: 0).code, '72590');
    expect(Stop(id: 'x_1', code: '99', name: 'x', position: const LatLng(0, 0), distanceMeters: 0).code, '99');
  });
}
