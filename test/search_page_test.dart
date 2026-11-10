import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/built_in/ehentai.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/components/search_favorites.dart';
import 'package:pica_comic/components/search_query_bar.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/search_query.dart';
import 'package:pica_comic/network/base_comic.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/pre_search_page.dart';
import 'package:pica_comic/pages/search_result_page.dart';
import 'package:pica_comic/tools/tags_translation.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final searches = <(String, String, List<String>)>[];
  const screenshotKey = ValueKey('search-ui-screenshot');
  late Directory dataDirectory;

  ComicSource source(String key, String name) => ComicSource.named(
        name: name,
        key: key,
        filePath: 'test',
        searchPageData: SearchPageData.named(
          enableLanguageFilter: key != 'plain',
          enableTagsSuggestions: key != 'plain',
          searchOptions: [
            SearchOptions(
                LinkedHashMap.of({'recent': 'Recent', 'popular': 'Popular'}),
                'Order'),
          ],
          loadPage: (keyword, page, options) async {
            searches.add((key, keyword, List.of(options)));
            return const Res(<BaseComic>[], subData: 1);
          },
        ),
      );

  setUpAll(() async {
    dataDirectory = await Directory.systemTemp.createTemp('pica-search-ui-');
    App.dataPath = dataDirectory.path;
    App.cachePath = dataDirectory.path;
    AppTranslation.translations = {};
    final font = FontLoader('search-test');
    font.addFont(Future.value(ByteData.sublistView(
        File('fonts/NotoSansSC-Regular.ttf').readAsBytesSync())));
    await font.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    await TagsTranslation.readData();
    for (final tags in [
      TagsTranslation.femaleTags,
      TagsTranslation.maleTags,
      TagsTranslation.parodyTags,
      TagsTranslation.characterTranslations,
      TagsTranslation.otherTags,
      TagsTranslation.mixedTags,
      TagsTranslation.languageTranslations,
      TagsTranslation.artistTags,
      TagsTranslation.groupTags,
      TagsTranslation.cosplayerTags,
    ]) {
      tags.clear();
    }
    TagsTranslation.femaleTags['long hair'] = '长发';
    TagsTranslation.maleTags['glasses'] = '眼镜';
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appdata = Appdata();
    appdata.settings[50] = 'cn';
    appdata.settings[63] = 'ehentai';
    appdata.settings[69] = '1';
    ComicSource.sources = [
      source('ehentai', 'Target A'),
      source('nhentai', 'Target B'),
      source('plain', 'Target C')
    ];
    searches.clear();
    App.mainNavigatorKey = App.navigatorKey;
  });

  tearDownAll(() async {
    final target = dataDirectory.absolute.path;
    expect(target.startsWith(Directory.systemTemp.absolute.path), isTrue);
    expect(dataDirectory.uri.pathSegments.where((s) => s.isNotEmpty).last,
        startsWith('pica-search-ui-'));
    await dataDirectory.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester, Widget page,
      {double width = 390}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RepaintBoundary(
      key: screenshotKey,
      child: MaterialApp(
        navigatorKey: App.navigatorKey,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, fontFamily: 'search-test'),
        home: page,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Finder field() => find.descendant(
      of: find.byType(SearchQueryBar), matching: find.byType(TextField));
  SearchQueryBar bar(WidgetTester tester) =>
      tester.widget<SearchQueryBar>(find.byType(SearchQueryBar));
  Future<void> tapSearch(WidgetTester tester) async {
    await tester.tap(find.descendant(
        of: find.byType(SearchQueryBar), matching: find.byIcon(Icons.search)));
    await tester.pumpAndSettle();
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('SEARCH_UI_SCREENSHOTS')) return;
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(screenshotKey));
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = await Directory('build/search-ui').create(recursive: true);
      await File('${output.path}/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
      'suggestions create removable chips and submission keeps manual input plain',
      (tester) async {
    await open(tester, const PreSearchPage());
    expect(find.text('language:chinese'), findsOneWidget);
    await tester.enterText(field(), 'ordinary long ha');
    await tester.pumpAndSettle();
    await tester.tap(find.text('long hair'));
    await tester.pumpAndSettle();
    expect(bar(tester).controller.query.text, 'ordinary ');
    expect(find.byType(InputChip), findsNWidgets(2));
    expect(find.text('female:long hair'), findsOneWidget);
    final removeHair = find.descendant(
        of: find.byWidgetPredicate((widget) =>
            widget is InputChip &&
            widget.key ==
                const ValueKey(SearchTag('long hair', namespace: 'female'))),
        matching: find.byTooltip('删除标签'));
    await tester.ensureVisible(removeHair);
    await tester.pumpAndSettle();
    await tester.tap(removeHair);
    await tester.pumpAndSettle();
    expect(bar(tester).controller.query.text, 'ordinary ');
    await tester.tap(find.byTooltip('删除标签'));
    await tester.pumpAndSettle();
    expect(find.byType(InputChip), findsNothing);
    await tapSearch(tester);
    expect(searches.single.$2, 'ordinary');
    expect(find.byType(InputChip), findsNothing);
    expect(bar(tester).controller.query.text, 'ordinary ');
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 1200.0]) {
    testWidgets(
        'favorites restore a full combination without submitting at width $width',
        (tester) async {
      await open(tester, const PreSearchPage(), width: width);
      await tester.enterText(field(), 'manual long ha');
      await tester.pumpAndSettle();
      await tester.tap(find.text('long hair'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OptionChip, 'Popular'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('收藏搜索组合'));
      await tester.pumpAndSettle();
      final saved = appdata.favoriteSearches.value.single;
      expect(saved.options, ['popular']);
      expect(saved.sourceKey, 'ehentai');
      final starX = tester.getCenter(find.byIcon(Icons.star)).dx;
      final searchX = tester
          .getCenter(find.descendant(
              of: find.byType(SearchQueryBar),
              matching: find.byIcon(Icons.search)))
          .dx;
      expect(starX, lessThan(searchX));
      await tester.tap(find.byTooltip('清除'));
      await tester.pumpAndSettle();
      expect(find.byType(InputChip), findsNothing);
      await tester.tap(find.text('收藏夹 (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(saved.query.keywordFor('ehentai')));
      await tester.pumpAndSettle();
      expect(bar(tester).controller.query, saved.query);
      expect(bar(tester).options, saved.options);
      expect(searches, isEmpty);
      expect(find.byType(InputChip), findsNWidgets(2));
      expect(find.byTooltip('取消收藏搜索组合'), findsOneWidget);
      await screenshot(tester, width < 600 ? 'mobile' : 'desktop');

      await tester.tap(find.text('Target B'));
      await tester.pumpAndSettle();
      expect(find.text('收藏夹 (0)'), findsOneWidget);
      expect(find.byTooltip('收藏搜索组合'), findsOneWidget);
      await tester.tap(find.byTooltip('收藏搜索组合'));
      await tester.pumpAndSettle();
      expect(appdata.favoriteSearches.value.map((item) => item.sourceKey),
          ['nhentai', 'ehentai']);
      await tester.tap(find.text('收藏夹 (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byType(SearchFavorites),
          matching: find.byTooltip('删除搜索组合')));
      await tester.pumpAndSettle();
      expect(appdata.favoriteSearches.value, [saved]);
      await tester.tap(find.text('Target A'));
      await tester.pumpAndSettle();
      expect(find.text('收藏夹 (1)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'result-page suggestions and favorite use the same structured query',
      (tester) async {
    await open(tester,
        const SearchResultPage(keyword: 'manual', sourceKey: 'ehentai'));
    expect(searches.single.$2, 'language:chinese manual');
    expect(find.text('language:chinese'), findsOneWidget);
    await tester.enterText(field(), 'manual long ha');
    await tester.pumpAndSettle();
    await tester.tap(find.text('long hair'));
    await tester.pumpAndSettle();
    expect(bar(tester).controller.query.text, 'manual ');
    expect(find.text('female:long hair'), findsOneWidget);
    expect(searches.length, 1);
    await tester.tap(find.byTooltip('收藏搜索组合'));
    await tester.pumpAndSettle();
    expect(appdata.favoriteSearches.value.single.query,
        bar(tester).controller.query);
    await tapSearch(tester);
    expect(searches.last.$2, 'language:chinese female:"long hair" manual');
    expect(tester.takeException(), isNull);
  });

  testWidgets('typed language syntax is never shown as a chip on result pages',
      (tester) async {
    await open(
        tester,
        const SearchResultPage(
            keyword: 'language:english words', sourceKey: 'ehentai'));
    expect(find.byType(InputChip), findsNothing);
    expect(searches.single.$2, 'language:english words');
    await tester.enterText(field(), 'typed words ');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('收藏搜索组合'));
    await tester.pumpAndSettle();
    expect(appdata.favoriteSearches.value.single.query.tags, isEmpty);
    expect(appdata.favoriteSearches.value.single.query.text, 'typed words ');
    expect(tester.takeException(), isNull);
  });

  testWidgets('clicked comic tags and automatic language both appear as chips',
      (tester) async {
    await open(
        tester,
        SearchResultPage.forTag(
            tag: 'female:"long hair"', sourceKey: 'ehentai'));
    expect(bar(tester).controller.query.text, isEmpty);
    expect(bar(tester).controller.tags, [
      const SearchTag('long hair', namespace: 'female'),
      const SearchTag('chinese', namespace: 'language'),
    ]);
    expect(find.byType(InputChip), findsNWidgets(2));
    expect(searches.single.$2, 'female:"long hair" language:chinese');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'language selector and chip deletion stay in sync with typed conditions',
      (tester) async {
    await open(tester, const PreSearchPage());
    await tester.enterText(field(), 'words language:english ');
    await tester.pumpAndSettle();
    expect(find.byType(InputChip), findsNothing);
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('japanese').last);
    await tester.pumpAndSettle();
    expect(bar(tester).controller.language, 'japanese');
    expect(bar(tester).controller.query.text, 'words  ');
    await tapSearch(tester);
    expect(searches.single.$2, 'language:japanese words');
    expect(tester.takeException(), isNull);
  });

  testWidgets('restored E-Hentai advanced fields show their stored values',
      (tester) async {
    ComicSource.sources = [ehentai];
    final saved = SavedSearch(
        sourceKey: 'ehentai',
        query: SearchQuery(text: 'manual'),
        options: ['0', '12', '40', '3', '0']);
    appdata.favoriteSearches.value = [saved];
    await open(tester, const PreSearchPage(), width: 1200);
    await tester.tap(find.text('收藏夹 (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('manual'));
    await tester.pumpAndSettle();
    expect(bar(tester).options, saved.options);
    expect(bar(tester).controller.tags, isEmpty);
    final fields = tester.widgetList<TextFormField>(find.byType(TextFormField));
    expect(fields.map((field) => field.initialValue), ['12', '40']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching to a source without filters removes the language chip',
      (tester) async {
    await open(tester, const PreSearchPage());
    await tester.tap(find.text('Target C'));
    await tester.pumpAndSettle();
    expect(find.byType(InputChip), findsNothing);
    await tester.tap(find.byTooltip('收藏搜索组合'));
    await tester.pumpAndSettle();
    expect(appdata.favoriteSearches.value.single.query.tags, isEmpty);
    await tester.tap(find.text('Target A'));
    await tester.pumpAndSettle();
    expect(find.text('language:chinese'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'canceling result options preserves the current search combination',
      (tester) async {
    await open(
        tester, const SearchResultPage(keyword: 'manual', sourceKey: 'ehentai'),
        width: 800);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Popular'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('搜索选项'))).pop();
    await tester.pumpAndSettle();
    expect(bar(tester).options, ['recent']);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Popular'));
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(bar(tester).options, ['popular']);
    expect(searches.last.$3, ['popular']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'custom result pages receive the structured query without adding deleted filters',
      (tester) async {
    SearchQuery? received;
    ComicSource.sources = [
      ComicSource.named(
        name: 'Custom results',
        key: 'hitomi',
        filePath: 'test',
        searchPageData: SearchPageData.named(
            enableLanguageFilter: true,
            overrideSearchResultBuilder: (query, options) {
              received = query;
              return const Scaffold(body: Text('Custom results'));
            }),
      )
    ];
    final query = SearchQuery(
        text: 'manual',
        tags: [const SearchTag('long hair', namespace: 'female')]);
    await open(
        tester,
        SearchResultPage(
            keyword: query.keywordFor('hitomi'),
            query: query,
            sourceKey: 'hitomi'));
    expect(received, query);
    expect(received!.tags.any((tag) => tag.isLanguage), isFalse);
    expect(received!.keywordFor('hitomi'), 'female:long_hair manual');
  });

  testWidgets('no enabled search sources shows an empty state', (tester) async {
    ComicSource.sources = [];
    await open(tester, const PreSearchPage());
    expect(find.text('没有可用的搜索目标'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving a loading search before its response arrives is safe',
      (tester) async {
    final response = Completer<Res<List<int>>>();
    await tester
        .pumpWidget(MaterialApp(home: _DeferredSearch(response.future)));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    response.complete(const Res(<int>[]));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

class _DeferredSearch extends StatefulWidget {
  const _DeferredSearch(this.response);

  final Future<Res<List<int>>> response;

  @override
  State<_DeferredSearch> createState() => _DeferredSearchState();
}

class _DeferredSearchState extends LoadingState<_DeferredSearch, List<int>> {
  @override
  Future<Res<List<int>>> loadData() => widget.response;

  @override
  Widget buildContent(BuildContext context, List<int> data) =>
      const Text('Results');
}
