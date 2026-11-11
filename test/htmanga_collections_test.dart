import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/built_in/ht_manga.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/htmanga_network/ht_download_model.dart';
import 'package:pica_comic/network/htmanga_network/htmanga_main_network.dart';
import 'package:pica_comic/network/htmanga_network/models.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/pages/reader/comic_reading_page.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:pica_comic/tools/download_runtime.dart';
import 'package:sqlite3/open.dart';

String chapterLinks(Iterable<int> ids) => ids
    .map((id) => '<a class="tagshow" data-chid="$id" '
        'href="/photos-slide-aid-$id-sid-900.html" '
        'title="Chapter $id">Chapter $id</a>')
    .join();

String comicDetails({int? chapterCount, String chapters = ''}) => '''
  <div class="userwrap">
    <h2>Comic 900</h2>
    <div class="asTB">
      <div class="asTBcell uwthumb"><img src="////img.example/cover.jpg"></div>
      <div class="asTBcell uwconn">
        <label>分類：單行本／合集</label>
        <label>${chapterCount == null ? '頁數：24P' : '章節：$chapterCount 話'}</label>
        <label>收藏：10</label>
        <div class="addtags"><a class="tagshow" href="/albums-index-tag-test.html">Test</a></div>
        <p>Description</p>
      </div>
      <div class="asTBcell uwuinfo">
        <a><img src="userpic/avatar.jpg"><p>Uploader</p></a>
        <p><font>7</font></p>
      </div>
    </div>
  </div>
  ${chapterCount == null ? '<div class="pic_box tb"><a><img src="//img.example/thumbnail.jpg"></a></div>' : '''
    <div id="sr_pub" data-order="asc" data-page="1" data-total="$chapterCount"
      data-per="12" data-pageurl="/photos-index-aid-900-page-%5B%23page%23%5D.html"></div>
    <div class="sr_compact">$chapters</div>
  '''}
''';

HtComicInfo comic({Map<String, String> chapters = const {}}) => HtComicInfo(
    '900',
    'https://img.example/cover.jpg',
    'Comic 900',
    'Test',
    chapters.isEmpty ? 24 : 0,
    const {},
    '',
    'Uploader',
    '',
    0,
    const [],
    chapters: chapters);

// Exercise the real download queue and file layout without remote image data.
class _FixtureHtDownload extends DownloadingHtComic {
  _FixtureHtDownload(DownloadingHtComic item)
      : super(item.comic, item.onFinish, item.onError, item.updateInfo, item.id,
            downloadEps: List<int>.from(item.toMap()['downloadEps']));

  @override
  Future<void> downloadCover() async {
    await File('$path/cover.jpg').writeAsBytes([0]);
  }

  @override
  Stream<DownloadProgress> downloadImage(String link,
      {CancelToken? cancelToken}) async* {
    final bytes = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 0, 0]);
    yield DownloadProgress(bytes.length, bytes.length, link, '', bytes);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  final responses = <String, String>{};
  final requests = <Uri>[];

  setUpAll(() {
    App.dataPath = Directory.systemTemp.path;
    AppTranslation.translations = {};
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    }
    SingleInstanceCookieJar(':memory:');
  });

  setUp(() async {
    responses.clear();
    requests.clear();
    htManga.data.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    appdata.settings[31] = 'http://127.0.0.1:${server.port}/';
    appdata.settings[8] = '';
    appdata.settings[50] = 'cn';
    proxyHttpOverrides = null;
    server.listen((request) async {
      requests.add(request.uri);
      request.response.headers.contentType = ContentType.html;
      final html = responses[request.uri.path];
      request.response.statusCode = html == null ? 404 : 200;
      request.response.write(html ?? 'Not found');
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  tearDownAll(() {
    SingleInstanceCookieJar.instance!.dispose();
    SingleInstanceCookieJar.instance = null;
  });

  test('loads the complete collection directory in website order', () async {
    responses['/photos-index-page-1-aid-900.html'] = comicDetails(
        chapterCount: 13,
        chapters: chapterLinks(Iterable.generate(12, (i) => 101 + i)));
    responses['/photos-index-aid-900-page-2.html'] =
        '<div class="sr_compact">${chapterLinks([112, 113])}</div>';

    final result = await HtmangaNetwork().getComicInfo('900');

    expect(result.error, isFalse, reason: result.errorMessage);
    final info = result.data;
    expect(info.isCollection, isTrue);
    expect(info.pages, 0);
    expect(info.chapters.keys, List.generate(13, (i) => '${101 + i}'));
    expect(
        info.chapters.values, List.generate(13, (i) => 'Chapter ${101 + i}'));
    expect(info.tags, {'Test': '/albums-index-tag-test.html'});
    expect(info.toBrief().chapterCount, 13);
    expect(info.coverPath, 'http://img.example/cover.jpg');
    expect(info.avatar, '${HtmangaNetwork.baseUrl}/userpic/avatar.jpg');
    expect(requests.map((uri) => uri.path), [
      '/photos-index-page-1-aid-900.html',
      '/photos-index-aid-900-page-2.html',
    ]);
  });

  test('does not return a partial directory when a later page fails', () async {
    responses['/photos-index-page-1-aid-900.html'] = comicDetails(
        chapterCount: 13,
        chapters: chapterLinks(Iterable.generate(12, (i) => 101 + i)));
    responses['/photos-index-aid-900-page-2.html'] =
        '<div class="title_c">您沒有權限，需要登錄！</div>';

    final result = await HtmangaNetwork().getComicInfo('900');

    expect(result.error, isTrue);
    expect(result.errorMessage, '未登录或登录到期');
    expect(result.dataOrNull, isNull);
  });

  test('rejects an empty or incomplete collection directory', () async {
    for (final ids in [
      <int>[],
      [101]
    ]) {
      responses['/photos-index-page-1-aid-900.html'] =
          comicDetails(chapterCount: 2, chapters: chapterLinks(ids));

      final result = await HtmangaNetwork().getComicInfo('900');

      expect(result.error, isTrue);
      expect(result.dataOrNull, isNull);
    }
  });

  test('keeps ordinary page counts, tags and thumbnails', () async {
    responses['/photos-index-page-1-aid-900.html'] = comicDetails();

    final result = await HtmangaNetwork().getComicInfo('900');

    expect(result.error, isFalse, reason: result.errorMessage);
    expect(result.data.pages, 24);
    expect(result.data.isCollection, isFalse);
    expect(result.data.toBrief().chapterCount, isNull);
    expect(result.data.thumbnails, ['http://img.example/thumbnail.jpg']);
  });

  test('reader requests the selected chapter under the collection identity',
      () async {
    responses['/photos-gallery-aid-102.html'] =
        'var imglist = [{url: "//img.example/102.jpg?verify=a_b-1&v=2"}];';
    final reader = HtReadingData(
        'Collection', '900', {'101': 'Chapter 1', '102': 'Chapter 2'});

    final result = await reader.loadEpNetwork(2);

    expect(reader.hasEp, isTrue);
    expect(reader.id, '900');
    expect(reader.downloadId, 'Ht900');
    expect(result.data, ['http://img.example/102.jpg?verify=a_b-1&v=2']);
    expect(requests.single.path, '/photos-gallery-aid-102.html');
  });

  test('ordinary reader still requests the comic ID', () async {
    responses['/photos-gallery-aid-900.html'] =
        'var imglist = [{url: "//img.example/900.jpg"}];';
    final reader = HtReadingData('Comic', '900');

    final result = await reader.loadEpNetwork(1);

    expect(reader.hasEp, isFalse);
    expect(result.data, ['http://img.example/900.jpg']);
    expect(requests.single.path, '/photos-gallery-aid-900.html');
  });

  test('selected downloads keep their original episode numbers', () async {
    for (final id in [101, 103]) {
      responses['/photos-gallery-aid-$id.html'] =
          'var imglist = [{url: "//img.example/$id.jpg"}];';
    }
    final item = DownloadingHtComic(
        comic(chapters: {'101': 'One', '102': 'Two', '103': 'Three'}),
        () {},
        () {},
        () async {},
        'Ht900',
        downloadEps: [2, 0]);

    final links = await item.getLinks();

    expect(item.haveEps, isTrue);
    expect(links, {
      1: ['http://img.example/101.jpg'],
      3: ['http://img.example/103.jpg'],
    });
    expect(links.keys, [1, 3]);
    expect(
        requests.map((uri) => uri.path),
        unorderedEquals([
          '/photos-gallery-aid-101.html',
          '/photos-gallery-aid-103.html',
        ]));
  });

  test('downloads all collection chapters by default for favorite downloads',
      () async {
    for (final id in [101, 102]) {
      responses['/photos-gallery-aid-$id.html'] =
          'var imglist = [{url: "//img.example/$id.jpg"}];';
    }
    final item = DownloadingHtComic(
        comic(chapters: {'101': 'One', '102': 'Two'}),
        () {},
        () {},
        () async {},
        'Ht900');

    expect((await item.getLinks()).keys, [1, 2]);
  });

  test('keeps selected chapter IDs when restoring the queue', () async {
    responses['/photos-gallery-aid-102.html'] =
        'var imglist = [{url: "//img.example/102.jpg"}];';
    final item = DownloadingHtComic(
        comic(chapters: {'101': 'One', '102': 'Two'}),
        () {},
        () {},
        () async {},
        'Ht900',
        downloadEps: [1]);
    final restored = DownloadingHtComic.fromMap(
        jsonDecode(jsonEncode(item.toMap())),
        () {},
        () {},
        () async {},
        'Ht900');

    expect(restored.haveEps, isTrue);
    expect((await restored.getLinks()).keys, [2]);
    expect(requests.single.path, '/photos-gallery-aid-102.html');
  });

  test('preserves downloaded chapters and chapter names across JSON storage',
      () {
    final downloaded = DownloadedHtComic(
        comic(chapters: {'101': 'One', '102': 'Two', '103': 'Three'}),
        1.5,
        [0, 2]);
    final restored =
        DownloadedHtComic.fromJson(jsonDecode(jsonEncode(downloaded.toJson())));

    expect(restored.comic.isCollection, isTrue);
    expect(restored.eps, ['One', 'Two', 'Three']);
    expect(restored.downloadedEps, [0, 2]);
    restored.downloadedEps.remove(0);
    expect(restored.toJson()['downloadedChapters'], [2]);
  });

  test('incremental downloads preserve chapters and read their files offline',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('pica-ht-collections-');
    final previousManager = DownloadManager.cache;
    final previousGlobalManager = downloadManager;
    DownloadManager.cache = null;
    final manager = DownloadManager();
    downloadManager = manager;
    appdata.settings[22] = directory.path;
    appdata.settings[79] = '2';
    appdata.settings[90] = '0';
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DownloadRuntime.channel, (call) async => null);
    await manager.init();
    addTearDown(() async {
      manager.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      binding.defaultBinaryMessenger
          .setMockMethodCallHandler(DownloadRuntime.channel, null);
      DownloadRuntime.channel.setMethodCallHandler(null);
      DownloadManager.cache = previousManager;
      downloadManager = previousGlobalManager;
      expect(
          directory.absolute.path
              .startsWith(Directory.systemTemp.absolute.path),
          isTrue);
      expect(directory.uri.pathSegments.where((s) => s.isNotEmpty).last,
          startsWith('pica-ht-collections-'));
      await directory.delete(recursive: true);
    });
    final info = comic(chapters: {'101': 'One', '102': 'Two'});
    for (final id in [101, 102]) {
      responses['/photos-gallery-aid-$id.html'] =
          'var imglist = [{url: "//img.example/$id.jpg"}];';
    }
    Future<void> download(List<int> eps) async {
      manager.isDownloading = true;
      manager.addHtDownload(info, eps);
      final item = _FixtureHtDownload(
          manager.downloading.removeLast() as DownloadingHtComic);
      manager.downloading.add(item);
      manager.isDownloading = false;
      await manager.start();
      for (var i = 0; i < 200 && manager.isDownloading; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(manager.isDownloading, isFalse);
      expect(manager.error, isFalse);
    }

    await download([1]);
    final first = (await manager.getComicOrNull('Ht900'))!;
    expect(first.downloadedEps, [1]);
    expect(await manager.getEpLength('Ht900', 2), 1);
    final reader = HtReadingData(info.title, info.id, info.chapters);
    requests.clear();
    expect((await reader.loadEp(2)).data, ['']);
    expect(requests, isEmpty);
    expect(reader.checkEpDownloaded(1), isFalse);
    final image = await reader.loadImage(2, 0, '').last;
    expect(image.savePath, manager.getImage('Ht900', 2, 0).path);

    await download([0]);
    final merged = (await manager.getComicOrNull('Ht900'))!;
    expect(merged.downloadedEps, [0, 1]);
    expect(await manager.getEpLength('Ht900', 1), 1);
    expect(await manager.getEpLength('Ht900', 2), 1);
    expect(await manager.deleteEpisode(merged, 1), isNull);
    final remaining = (await manager.getComicOrNull('Ht900'))!;
    expect(remaining.downloadedEps, [0]);
  });

  test('loads old single-comic downloads and queued tasks', () async {
    responses['/photos-gallery-aid-900.html'] =
        'var imglist = [{url: "//img.example/900.jpg"}];';
    final oldComic = comic().toJson()..remove('chapters');
    final downloaded =
        DownloadedHtComic.fromJson({'comic': oldComic, 'size': 1.0});
    final oldQueue =
        DownloadingHtComic(comic(), () {}, () {}, () async {}, 'Ht900').toMap()
          ..['comic'] = oldComic
          ..remove('downloadEps');
    final restored = DownloadingHtComic.fromMap(
        oldQueue, () {}, () {}, () async {}, 'Ht900');

    expect(downloaded.comic.chapters, isEmpty);
    expect(downloaded.downloadedEps, [0]);
    expect(downloaded.eps, ['EP 1']);
    expect(restored.haveEps, isFalse);
    expect(await restored.getLinks(), {
      0: ['http://img.example/900.jpg']
    });
  });
}
