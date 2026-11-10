import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/search_query.dart';
import 'package:pica_comic/network/webdav.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dataDirectory;

  SavedSearch saved(String source, {String text = 'manual words'}) =>
      SavedSearch(
        sourceKey: source,
        query: SearchQuery(
            text: text,
            tags: [const SearchTag('long hair', namespace: 'female')]),
        options: ['popular'],
      );

  setUpAll(() async {
    dataDirectory = await Directory.systemTemp.createTemp('pica-search-tests-');
    App.dataPath = dataDirectory.path;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    appdata = Appdata();
    final settingsFile = File('${dataDirectory.path}/settings');
    if (await settingsFile.exists()) await settingsFile.delete();
  });

  tearDownAll(() async {
    final target = dataDirectory.absolute.path;
    expect(target.startsWith(Directory.systemTemp.absolute.path), isTrue);
    expect(dataDirectory.uri.pathSegments.where((s) => s.isNotEmpty).last,
        startsWith('pica-search-tests-'));
    await dataDirectory.delete(recursive: true);
  });

  test('favorites survive restart, remove independently and persist deletion',
      () async {
    final a = saved('ehentai');
    final b = saved('nhentai');
    await appdata.toggleFavoriteSearch(a);
    await appdata.toggleFavoriteSearch(b);
    final restarted = Appdata();
    await restarted.readData();
    expect(restarted.favoriteSearches.value, [b, a]);
    await restarted.removeFavoriteSearch(a);
    final nextRestart = Appdata();
    await nextRestart.readData();
    expect(nextRestart.favoriteSearches.value, [b]);
    await nextRestart.toggleFavoriteSearch(b);
    expect(nextRestart.favoriteSearches.value, isEmpty);
    final preferences = await SharedPreferences.getInstance();
    expect(jsonDecode(preferences.getString('favoriteSearches')!), isEmpty);
  });

  test('user-data export/import preserves structured queries and options',
      () async {
    await appdata.toggleFavoriteSearch(saved('ehentai'));
    await appdata.toggleFavoriteSearch(saved('nhentai', text: 'other text'));
    final payload =
        jsonDecode(jsonEncode(appdata.toJson())) as Map<String, dynamic>;
    final imported = Appdata();
    expect(await imported.readDataFromJson(payload), isTrue);
    expect(imported.favoriteSearches.value, appdata.favoriteSearches.value);
    final restarted = Appdata();
    await restarted.readData();
    expect(restarted.favoriteSearches.value, imported.favoriteSearches.value);
  });

  test('sync applies deletions and old backups preserve local search favorites',
      () async {
    await appdata.toggleFavoriteSearch(saved('ehentai'));
    final oldPayload = appdata.toJson()..remove('favoriteSearches');
    expect(await appdata.readDataFromJson(oldPayload), isTrue);
    expect(appdata.favoriteSearches.value, [saved('ehentai')]);
    final deletedSnapshot = appdata.toJson()..['favoriteSearches'] = [];
    expect(await appdata.readDataFromJson(deletedSnapshot), isTrue);
    expect(appdata.favoriteSearches.value, isEmpty);
    final restarted = Appdata();
    await restarted.readData();
    expect(restarted.favoriteSearches.value, isEmpty);
  });

  test('invalid saved data leaves settings and valid favorites available',
      () async {
    SharedPreferences.setMockInitialValues({
      'favoriteSearches': jsonEncode([
        {'sourceKey': null},
        saved('ehentai').toJson()
      ]),
    });
    await appdata.readData();
    expect(appdata.favoriteSearches.value, [saved('ehentai')]);
    SharedPreferences.setMockInitialValues(
        {'favoriteSearches': 'invalid JSON'});
    await appdata.readData();
    expect(appdata.favoriteSearches.value, isEmpty);
  });

  test('rapid sync snapshots always advance the data version', () async {
    final previous = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 1000;
    appdata.settings[46] = previous.toString();
    await Webdav.uploadData('');
    final firstVersion = int.parse(appdata.settings[46]);
    await Webdav.uploadData('');
    expect(firstVersion, greaterThan(previous));
    expect(int.parse(appdata.settings[46]), greaterThan(firstVersion));
    await appdata.updateSettings(false);
  });
}
