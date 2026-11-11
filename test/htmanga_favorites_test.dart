import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/built_in/ht_manga.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/htmanga_network/htmanga_main_network.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:sqlite3/open.dart';

String favoriteComic({
  String id = '123',
  String favoriteId = '456',
  String? info = '分類：同人志，頁數：24',
}) =>
    '''
    <div class="asTB">
      <div class="asTBcell thumb"><div>
        <img src="//img.example/$id.jpg?verify=signature">
      </div></div>
      <div class="box_cel u_listcon">
        <p class="l_catg"><span>創建時間：2026-11-12</span></p>
        <p class="l_title"><a href="/photos-index-aid-$id.html">Comic $id</a></p>
        ${info == null ? '' : '<p class="l_detla">$info</p>'}
        <p class="alopt"><a onclick="del('/users-fav_del-id-$favoriteId.html')">刪除</a></p>
      </div>
    </div>
    ''';

void main() {
  late HttpServer server;
  late String responseHtml;
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
    responseHtml = '';
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
      request.response.write(responseHtml);
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

  test('loads favorite metadata and pagination for the requested folder',
      () async {
    responseHtml = '''
      ${favoriteComic()}
      <div class="f_left paginator"><a>1</a><a>2</a><a>4</a></div>
    ''';

    final result = await HtmangaNetwork().getFavoriteFolderComics('99', 2);

    expect(result.error, isFalse, reason: result.errorMessage);
    final comic = result.data.single;
    expect(comic.id, '123');
    expect(comic.favoriteId, '456');
    expect(comic.name, 'Comic 123');
    expect(comic.time, '2026-11-12');
    expect(comic.cover, 'http://img.example/123.jpg?verify=signature');
    expect(comic.pages, 24);
    expect(result.subData, 4);
    expect(requests.single.path, '/users-users_fav-page-2-c-99.html');
  });

  for (final label in [
    '頁數： 24',
    '頁數:24',
    '頁數 \n：\t24',
    '页数：24',
    '页数: 24',
    '頁數：&nbsp;24',
  ]) {
    test('loads favorites with page count formatted as $label', () async {
      responseHtml = favoriteComic(info: '分類：同人志，$label');

      final result = await HtmangaNetwork().getFavoriteFolderComics('99', 1);

      expect(result.error, isFalse, reason: result.errorMessage);
      expect(result.data.single.pages, 24);
      expect(result.data.single.favoriteId, '456');
    });
  }

  for (final info in [
    null,
    '',
    '分類：同人志，觀看：1234',
    '分類：同人志，頁數：未知',
  ]) {
    test('keeps every favorite when one comic has missing page metadata: $info',
        () async {
      responseHtml = favoriteComic(id: '101', favoriteId: '201') +
          favoriteComic(id: '102', favoriteId: '202', info: info) +
          favoriteComic(id: '103', favoriteId: '203');

      final result = await HtmangaNetwork().getFavoriteFolderComics('99', 1);

      expect(result.error, isFalse, reason: result.errorMessage);
      expect(result.data.map((comic) => comic.id), ['101', '102', '103']);
      expect(result.data.map((comic) => comic.pages), [24, 0, 24]);
      expect(
          result.data.map((comic) => comic.favoriteId), ['201', '202', '203']);
      expect(result.subData, 1);
    });
  }

  test('loads an empty folder without pagination', () async {
    responseHtml = '<div>暫無收藏</div>';

    final result = await HtmangaNetwork().getFavoriteFolderComics('99', 1);

    expect(result.error, isFalse, reason: result.errorMessage);
    expect(result.data, isEmpty);
    expect(result.subData, 1);
  });

  test('still reports an expired login as an error', () async {
    responseHtml = '<div class="title_c">您沒有權限，需要登錄！</div>';

    final result = await HtmangaNetwork().getFavoriteFolderComics('99', 1);

    expect(result.error, isTrue);
    expect(result.errorMessage, '未登录或登录到期');
  });
}
