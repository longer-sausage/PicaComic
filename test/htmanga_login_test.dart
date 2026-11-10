import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/built_in/ht_manga.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/htmanga_network/htmanga_main_network.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:sqlite3/open.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('webview_window');
  const codec = StandardMethodCodec();
  late HttpServer server;
  late String baseUrl;
  late String pageUrl;
  late bool authenticated;
  late bool completeWebLogin;
  late String browserCookie;
  late String submittedScript;
  var viewId = 0;
  var imageRequests = 0;
  final requests = <HttpHeaders>[];

  Future<void> windowClosed() async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'webview_window',
      codec.encodeMethodCall(MethodCall('onWindowClose', {'id': viewId})),
      (_) {},
    );
  }

  setUpAll(() {
    App.dataPath = Directory.systemTemp.path;
    AppTranslation.translations = {};
    if (Platform.isWindows) {
      // Use Windows' bundled SQLite; no app plugin DLL is needed by these tests.
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    }
    SingleInstanceCookieJar(':memory:');
    ComicSource.sources = [htManga];
  });

  setUp(() async {
    authenticated = false;
    completeWebLogin = true;
    browserCookie = 'verified-session';
    submittedScript = '';
    imageRequests = 0;
    requests.clear();
    htManga.data.clear();
    SingleInstanceCookieJar.instance!.deleteAll();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    appdata.settings[31] = '$baseUrl/';
    appdata.settings[8] = '';
    appdata.settings[50] = 'cn';
    proxyHttpOverrides = null;
    server.listen((request) async {
      requests.add(request.headers);
      request.response.headers.contentType = ContentType.html;
      if (request.headers.value('cookie') != 'auth=verified-session') {
        request.response.write('<div class="title_c">您沒有權限，需要登錄！</div>');
      } else if (request.uri.path == '/users-users_fav.html') {
        request.response.write('<a href="/users-logout.html">退出</a>');
      } else if (request.uri.path.startsWith('/photos-gallery-')) {
        imageRequests++;
        request.response.write('document.writeln(${jsonEncode('''
          var imglist = [{url: fast_img_host+"//img.example/0001.jpg?verify=signature-$imageRequests"}];
        ''')});');
      } else {
        request.response.write('''
          <div class="grid"><div class="gallary_wrap"><ul class="cc"><li>
            <div class="pic_box"><a href="/photos-index-aid-123.html">
              <img src="//img.example/cover.jpg"></a></div>
            <div class="info"><div class="title"><a title="Test Comic">Test Comic</a></div>
              <div class="info_col">2頁，2026-11-10</div></div>
          </li></ul></div></div>
        ''');
      }
      await request.response.close();
    });

    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      final args = call.arguments as Map? ?? {};
      switch (call.method) {
        case 'isWebviewAvailable':
          return true;
        case 'create':
          return ++viewId;
        case 'launch':
          pageUrl = args['url'] as String;
          if (!completeWebLogin) {
            unawaited(Future<void>.delayed(
                const Duration(milliseconds: 50), windowClosed));
          }
          return null;
        case 'evaluateJavaScript':
          final script = args['javaScriptString'] as String;
          if (script.contains('function collect()')) {
            return jsonEncode({
              'id': 'document_created',
              'data': {'title': '紳士漫畫', 'ua': 'Ht-Test-UA'}
            });
          }
          if (script.contains('ready: document.readyState')) {
            return jsonEncode({
              'url': pageUrl,
              'ready': 'complete',
              'authenticated': authenticated,
              'userAgent': 'Ht-Test-UA',
            });
          }
          if (script.startsWith('location.replace')) {
            pageUrl = '$baseUrl/users-login.html';
          } else if (script.contains('form.dataset.picaLogin')) {
            submittedScript = script;
            authenticated = true;
            pageUrl = '$baseUrl/albums.html';
          }
          return null;
        case 'getAllCookies':
          return [
            {
              'name': 'auth',
              'value': browserCookie,
              'domain': '127.0.0.1',
              'path': '/',
              'httpOnly': true
            },
            {
              'name': 'other',
              'value': 'private',
              'domain': 'other.example',
              'path': '/'
            },
          ];
        case 'close':
          unawaited(windowClosed());
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  tearDownAll(() {
    SingleInstanceCookieJar.instance!.dispose();
    SingleInstanceCookieJar.instance = null;
  });

  test(
      'verified browser cookies load protected content and fresh signed images',
      () async {
    final result = await HtmangaNetwork().login('test"user', 'test\\password');
    expect(result.error, isFalse, reason: result.errorMessage);
    expect(submittedScript, contains(jsonEncode('test"user')));
    expect(submittedScript, contains(jsonEncode('test\\password')));
    expect(htManga.data['userAgent'], 'Ht-Test-UA');
    final comics =
        await HtmangaNetwork().getComicList('$baseUrl/albums.html', 1);
    expect(comics.error, isFalse);
    expect(comics.data.single.id, '123');
    expect(comics.data.single.pages, 2);
    expect((await HtmangaNetwork().getImages('123')).data.single,
        'http://img.example/0001.jpg?verify=signature-1');
    expect((await HtmangaNetwork().getImages('123')).data.single,
        'http://img.example/0001.jpg?verify=signature-2');
    for (final headers in requests) {
      expect(headers.value('cookie'), 'auth=verified-session');
      expect(headers.value('user-agent'), 'Ht-Test-UA');
      expect(headers.value('referer'), '$baseUrl/');
    }
  });

  test('an unrecognized session cannot report login success or replace account',
      () async {
    browserCookie = 'invalid-session';
    htManga.data.addAll({
      'account': ['old-user', 'old-password'],
      'userAgent': 'Old-UA'
    });
    SingleInstanceCookieJar.instance!
        .saveFromResponse(Uri.parse(baseUrl), [Cookie('auth', 'old-session')]);
    final result = await htManga.account!.login!('new-user', 'new-password');
    expect(result.error, isTrue);
    expect(htManga.data['account'], ['old-user', 'old-password']);
    expect(htManga.data['userAgent'], 'Old-UA');
    expect(
        SingleInstanceCookieJar.instance!
            .loadForRequestCookieHeader(Uri.parse(baseUrl)),
        'auth=old-session');
  });

  test('closing the verification window finishes the login attempt', () async {
    completeWebLogin = false;
    final result = await HtmangaNetwork().login('test-user', 'test-password');
    expect(result.error, isTrue);
    expect(result.errorMessage, '已取消登录');
    expect(htManga.data['account'], isNull);
    expect(requests, isEmpty);
  });
}
