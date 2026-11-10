import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/htmanga_network/htmanga_parser.dart';

void main() {
  const baseUrl = 'https://www.wnacg.com/';

  test('normalizes website image URLs without losing signatures', () {
    for (final value in [
      '//cdn.example/cover.jpg?verify=a_b-123&size=2',
      '////cdn.example/cover.jpg?verify=a_b-123&size=2',
      'https:////cdn.example/cover.jpg?verify=a_b-123&size=2',
      'https://cdn.example/cover.jpg?verify=a_b-123&size=2',
    ]) {
      expect(
        HtMangaParser.resolveUrl(value, baseUrl),
        'https://cdn.example/cover.jpg?verify=a_b-123&size=2',
      );
    }
    expect(
      HtMangaParser.resolveUrl('userpic/avatar.jpg', baseUrl),
      '${baseUrl}userpic/avatar.jpg',
    );
  });

  test('detects expired sessions returned with HTTP 200', () {
    expect(
      HtMangaParser.requiresLogin('''
          <div class="title title_c">您沒有權限，需要登錄！</div>
          <a onclick="Mui.box.show('/users-login.html')">點擊這裡登錄</a>
        '''),
      isTrue,
    );
    expect(
      HtMangaParser.requiresLogin('<div class="title_c">您没有权限，需要登录！</div>'),
      isTrue,
    );
    expect(
      HtMangaParser.requiresLogin('<form id="login_form"></form>'),
      isTrue,
    );
    expect(
      HtMangaParser.requiresLogin(
        '<a href="/users-login.html">登錄</a><div class="grid"></div>',
      ),
      isFalse,
    );
  });

  test('requires an authenticated navigation marker', () {
    expect(
      HtMangaParser.isAuthenticated('<a href="/users-logout.html">退出登錄</a>'),
      isTrue,
    );
    expect(
      HtMangaParser.isAuthenticated(
        '<title>紳士漫畫</title><a href="/users-login.html">登錄</a>',
      ),
      isFalse,
    );
  });

  test(
    'reads the current gallery format and preserves the complete signature',
    () {
      const script = r'''
      <script src="//tracker.example/tracking.js"></script>
      var fast_img_host = "";
      var imglist = [
        {url: fast_img_host+"//img.example/data/1/0000.jpg?verify=123-A_b-xyz&v=1", caption: "[0000]"},
        {url: fast_img_host+"//img.example/data/1/0001.webp?verify=123-B\u0026v=2", caption: "[0001]"},
        {url: fast_img_host+"/themes/weitu/images/bg/shoucang.jpg", caption: "收藏"}
      ];
    ''';
      final response = script
          .split('\n')
          .map((line) => 'document.writeln(${jsonEncode(line)});')
          .join('\n');

      expect(HtMangaParser.galleryImages(response, baseUrl), [
        'https://img.example/data/1/0000.jpg?verify=123-A_b-xyz&v=1',
        'https://img.example/data/1/0001.webp?verify=123-B&v=2',
      ]);
    },
  );

  test('also reads unwrapped galleries and keeps page order', () {
    expect(
      HtMangaParser.galleryImages('''
          var imglist = [
            {url: '//img.example/2.png?verify=second'},
            {url: 'https://img.example/1.png?verify=first'},
            {url: '//img.example/2.png?verify=second'}
          ];
        ''', baseUrl),
      [
        'https://img.example/2.png?verify=second',
        'https://img.example/1.png?verify=first',
      ],
    );
  });

  test('decodes literal tabs and JavaScript escapes used by the live endpoint',
      () {
    const source = 'document.writeln("\tvar imglist = '
        r'''[{url: fast_img_host+\"//img.example/1.jpg?verify=abc\\x26v=1\", caption: \"[0001]\"}];");''';
    expect(HtMangaParser.galleryImages(source, baseUrl),
        ['https://img.example/1.jpg?verify=abc&v=1']);
  });

  test(
    'does not treat unrelated scripts or an empty gallery as comic pages',
    () {
      for (final response in [
        '<script src="//example.com/script.js"></script>',
        'var imglist = [];',
        'var imglist = [{url: "/themes/weitu/images/bg/shoucang.jpg"}];',
      ]) {
        expect(
          () => HtMangaParser.galleryImages(response, baseUrl),
          throwsFormatException,
        );
      }
    },
  );
}
