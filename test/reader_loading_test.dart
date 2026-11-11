import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/scrollable_list/src/item_positions_listener.dart';
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/reader/comic_reading_page.dart';
import 'package:pica_comic/tools/translations.dart';

void main() {
  setUpAll(() => AppTranslation.translations = {});
  late List<String> settings;
  late List<String> implicitData;
  setUp(() {
    settings = List.of(appdata.settings);
    implicitData = List.of(appdata.implicitData);
    appdata.settings[9] = '1';
    appdata.settings[28] = '2';
    appdata.implicitData[1] = '0';
  });
  tearDown(() {
    appdata.settings.setAll(0, settings);
    appdata.implicitData.setAll(0, implicitData);
    BaseImageProvider.clearCache();
    ComicImage.clear();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  ComicReadingPageLogic reader(_ReadingData data, {int page = 1}) {
    final logic = ComicReadingPageLogic(1, data, page, () {});
    addTearDown(() async {
      logic.dispose();
      data.finishImages();
      await Future<void>.delayed(Duration.zero);
    });
    return logic;
  }

  testWidgets('chapter loading paints first, deduplicates, and primes page one',
      (tester) async {
    final data = _ReadingData();
    final logic = reader(data);
    logic.loadChapter();
    logic.loadChapter();
    expect(data.requests, isEmpty,
        reason: 'Source code must not block the first loading frame');
    await tester.pumpWidget(const SizedBox());
    expect(data.requests.keys, [1]);
    logic.loadChapter();
    await tester.pump();
    expect(data.requestCount, 1);
    data.requests[1]!.complete(const Res(['one', 'two', 'three']));
    await tester.pump();
    expect(logic.isLoading, isFalse);
    expect(data.startedPages, ['1/0']);
    data.images['1/0']!.result.complete(Uint8List(1));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(data.startedPages, ['1/0', '1/1', '1/2']);
  });

  testWidgets('switching chapters ignores a slow previous response',
      (tester) async {
    final data = _ReadingData();
    final logic = reader(data);
    logic.loadChapter();
    await tester.pumpWidget(const SizedBox());
    logic.jumpToChapter(2);
    logic.loadChapter();
    await tester.pump();
    data.requests[2]!.complete(const Res(['new chapter']));
    await tester.pump();
    data.requests[1]!.complete(const Res(['stale chapter']));
    await tester.pump();
    expect(logic.order, 2);
    expect(logic.urls, ['new chapter']);
    expect(data.startedPages, ['2/0']);
  });

  testWidgets('closing the reader ignores pending chapter completion',
      (tester) async {
    final data = _ReadingData();
    final logic = reader(data);
    logic.loadChapter();
    await tester.pumpWidget(const SizedBox());
    logic.dispose();
    data.requests[1]!.complete(const Res(['closed chapter']));
    await tester.pump();
    expect(logic.urls, isEmpty);
    expect(data.startedPages, isEmpty);
  });

  testWidgets('source exceptions leave a retryable error instead of waiting',
      (tester) async {
    final data = _ReadingData();
    final logic = reader(data);
    logic.loadChapter();
    await tester.pumpWidget(const SizedBox());
    data.requests[1]!.completeError(StateError('offline'));
    await tester.pump();
    expect(logic.isLoading, isFalse);
    expect(logic.errorMessage, contains('offline'));
    logic.change();
    logic.loadChapter();
    await tester.pump();
    data.requests[1]!.complete(const Res(['recovered']));
    await tester.pump();
    expect(logic.errorMessage, isNull);
    expect(logic.urls, ['recovered']);
    expect(data.requestCount, 2);
  });

  for (final mode in ['5', '6']) {
    for (final singleFirst in [false, true]) {
      testWidgets('mode $mode resumes the correct spread, single=$singleFirst',
          (tester) async {
        appdata.settings[9] = mode;
        appdata.implicitData[1] = singleFirst ? '1' : '0';
        final data = _ReadingData();
        final logic = reader(data, page: 2)
          ..urls = List.generate(8, (index) => '$index')
          ..isLoading = false;
        logic.prefetchImages();
        await tester.pumpWidget(const SizedBox());
        expect(logic.pageController.initialPage, singleFirst ? 2 : 1);
        expect(logic.index, singleFirst ? 2 : 1);
        expect(
            data.startedPages, singleFirst ? ['1/1', '1/2'] : ['1/0', '1/1']);
      });
    }
  }

  testWidgets('continuous reading prioritizes every visible page',
      (tester) async {
    appdata.settings[9] = '4';
    final data = _ReadingData();
    final logic = reader(data)
      ..urls = List.generate(12, (index) => '$index')
      ..isLoading = false;
    final positions = logic.itemScrollListener.itemPositions
        as ValueNotifier<Iterable<ItemPosition>>;
    positions.value = const [
      ItemPosition(index: 0, itemLeadingEdge: -2, itemTrailingEdge: -1),
      ItemPosition(index: 8, itemLeadingEdge: 2, itemTrailingEdge: 3),
      ItemPosition(index: 5, itemLeadingEdge: .7, itemTrailingEdge: 1.3),
      ItemPosition(index: 4, itemLeadingEdge: .1, itemTrailingEdge: .7),
    ];
    await tester.pumpWidget(const SizedBox());
    expect(logic.index, 5);
    expect(data.startedPages, ['1/4', '1/5', '1/6', '1/7', '1/8', '1/9']);
    positions.value = const [];
    expect(logic.index, 5, reason: 'A transient empty layout is harmless');
    data.images['1/4']!.result.complete(Uint8List(1));
    data.images['1/5']!.result.complete(Uint8List(1));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(data.startedPages,
        ['1/4', '1/5', '1/6', '1/7', '1/8', '1/9', '1/10', '1/11']);
  });

  testWidgets('continuous reading starts lookahead before page one completes',
      (tester) async {
    appdata.settings[9] = '4';
    final data = _ReadingData();
    final logic = reader(data);
    logic.loadChapter();
    await tester.pumpWidget(const SizedBox());
    data.requests[1]!.complete(Res(List.generate(20, (i) => '$i')));
    await tester.pump();
    expect(data.startedPages, ['1/0', '1/1', '1/2', '1/3', '1/4', '1/5']);
    data.images['1/1']!.result.complete(Uint8List(1));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(data.startedPages.last, '1/6');
    expect(data.images['1/0']!.result.isCompleted, isFalse);
  });

  testWidgets('continuous reading respects disabled lookahead', (tester) async {
    appdata.settings[9] = '4';
    appdata.settings[28] = '0';
    final data = _ReadingData();
    final logic = reader(data)
      ..urls = List.generate(20, (i) => '$i')
      ..isLoading = false;
    logic.prefetchImages();
    await tester.pumpWidget(const SizedBox());
    expect(data.startedPages, ['1/0']);
  });

  testWidgets('a saved page outside a shortened chapter stays in range',
      (tester) async {
    final data = _ReadingData();
    final logic = reader(data, page: 100);
    logic.loadChapter();
    await tester.pumpWidget(const SizedBox());
    data.requests[1]!.complete(const Res(['one', 'two']));
    await tester.pump();
    expect(logic.index, 2);
    expect(logic.pageController.initialPage, 2);
    expect(data.startedPages, ['1/1']);
  });

  testWidgets('loading is visible before bytes arrive and throughout decoding',
      (tester) async {
    final image = _ProgressImage();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: ComicImage(image: image),
      ),
    ));
    CircularProgressIndicator indicator() =>
        tester.widget(find.byType(CircularProgressIndicator));
    expect(indicator().value, isNull);
    image.completer.progress(0, 100);
    await tester.pump();
    expect(indicator().value, isNull);
    image.completer.progress(50, 100);
    await tester.pump();
    expect(indicator().value, .5);
    image.completer.progress(100, 100);
    await tester.pump();
    expect(indicator().value, isNull,
        reason: 'Keep animating while the completed bytes are decoding');
    final pixels = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(Colors.white, ui.BlendMode.src);
      final picture = recorder.endRecording();
      final result = await picture.toImage(16, 16);
      picture.dispose();
      return result;
    });
    image.completer.emit(pixels!);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.allRenderObjects.whereType<RenderImage>().single.image,
        isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('custom sources without chapters can construct image cache keys', () {
    final data = CustomReadingData('comic', 'title', null, null);
    expect(data.buildImageKey(1, 0, 'page.jpg'), 'comiccomicpage.jpg');
  });

  for (var mode = 1; mode <= 6; mode++) {
    testWidgets('real reader mode $mode loads and jumps without missing pixels',
        (tester) async {
      appdata.settings[9] = '$mode';
      appdata.settings[7] = '0';
      appdata.settings[14] = '0';
      appdata.settings[76] = '0';
      final oldHistory = HistoryManager.cache;
      final oldFavorites = LocalFavoritesManager.cache;
      HistoryManager.cache = _ReaderHistory();
      LocalFavoritesManager.cache = _ReaderFavorites();
      addTearDown(() {
        HistoryManager.cache = oldHistory;
        LocalFavoritesManager.cache = oldFavorites;
      });
      final data = _ReadingData();
      data.defaultBytes = (await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawColor(Colors.blue, ui.BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(80, 120);
        picture.dispose();
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        image.dispose();
        return bytes;
      }))!;
      final page = ComicReadingPage(data, 3, 1);
      final logic = StateController.find<ComicReadingPageLogic>();
      addTearDown(() {
        logic.dispose();
        data.finishImages();
      });
      await tester.pumpWidget(MaterialApp(
          navigatorKey: App.navigatorKey, theme: ThemeData.dark(), home: page));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      data.requests[1]!.complete(Res(List.generate(8, (i) => '$i')));
      await tester.pump();
      expect(data.startedPages.first, '1/2');

      Future<void> finishVisibleImages() async {
        for (var attempt = 0; attempt < 12; attempt++) {
          data.finishImages();
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)));
          await tester.pump(const Duration(milliseconds: 20));
        }
      }

      await finishVisibleImages();
      expect(logic.index, 3);
      expect(
          tester.allRenderObjects
              .whereType<RenderImage>()
              .where((pixels) => pixels.image != null),
          isNotEmpty);
      logic.jumpToPage(5);
      await tester.pump();
      await finishVisibleImages();
      expect(logic.index, 5);
      expect(
          tester.allRenderObjects
              .whereType<RenderImage>()
              .where((pixels) => pixels.image != null),
          isNotEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

class _ReadingData extends ReadingData {
  final requests = <int, Completer<Res<List<String>>>>{};
  final images = <String, _BytesImage>{};
  final startedPages = <String>[];
  int requestCount = 0;
  Uint8List defaultBytes = Uint8List(1);

  void finishImages() {
    for (final image in images.values) {
      if (!image.result.isCompleted) image.result.complete(defaultBytes);
    }
  }

  @override
  bool get downloaded => false;
  @override
  Future<Res<List<String>>> loadEpNetwork(int ep) {
    requestCount++;
    return (requests[ep] = Completer<Res<List<String>>>()).future;
  }

  @override
  ImageProvider createImageProvider(int ep, int page, String url) => images
      .putIfAbsent('$ep/$page', () => _BytesImage('$ep/$page', startedPages));
  @override
  Stream<DownloadProgress> loadImageNetwork(int ep, int page, String url) =>
      throw UnimplementedError();
  @override
  bool get hasEp => true;
  @override
  Map<String, String> get eps => const {'1': 'first', '2': 'second'};
  @override
  ComicType get type => ComicType.picacg;
  @override
  FavoriteType get favoriteType => FavoriteType.picacg;
  @override
  String get title => 'test';
  @override
  String get id => 'test';
  @override
  String get downloadId => 'test';
  @override
  String get sourceKey => 'test';
}

class _BytesImage extends BaseImageProvider<_BytesImage> {
  _BytesImage(this.key, this.started);

  @override
  final String key;
  final List<String> started;
  final result = Completer<Uint8List>();

  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) {
    started.add(key);
    return result.future;
  }

  @override
  Future<_BytesImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
}

class _ProgressImage extends ImageProvider<_ProgressImage> {
  final completer = _ProgressCompleter();

  @override
  Future<_ProgressImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
          _ProgressImage key, ImageDecoderCallback decode) =>
      completer;
}

class _ProgressCompleter extends ImageStreamCompleter {
  void progress(int loaded, int total) => reportImageChunkEvent(ImageChunkEvent(
      cumulativeBytesLoaded: loaded, expectedTotalBytes: total));
  void emit(ui.Image image) => setImage(ImageInfo(image: image));
}

class _ReaderHistory implements HistoryManager {
  @override
  History? findSync(String target) => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReaderFavorites implements LocalFavoritesManager {
  @override
  void onReadEnd(String target, FavoriteType type) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
