import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:pica_comic/comic_source/built_in/ht_manga.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/cache_network.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/htmanga_network/models.dart';
import 'package:pica_comic/network/htmanga_network/htmanga_parser.dart';
import 'package:pica_comic/network/htmanga_network/login.dart';
import 'package:pica_comic/network/app_dio.dart';
import 'package:pica_comic/network/res.dart';
import 'package:html/parser.dart';
import 'package:pica_comic/pages/pre_search_page.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/translations.dart';
import '../../base.dart';

class HtmangaNetwork {
  ///用于获取绅士漫画的网络请求类
  factory HtmangaNetwork() => _cache ?? (_cache = HtmangaNetwork._create());

  static HtmangaNetwork? _cache;

  HtmangaNetwork._create();

  static String get baseUrl => appdata.settings[31].replaceFirst(RegExp(r'/+$'), '');

  static Map<String, String> get headers => {
        'User-Agent': htManga.data['userAgent'] as String? ?? webUA,
        'Referer': '$baseUrl/',
      };

  void logout() {
    SingleInstanceCookieJar.instance?.deleteUri(Uri.parse(baseUrl));
  }

  ///基本的Get请求
  Future<Res<String>> get(String url,
      {bool cache = true, Map<String, String>? headers}) async {
    var dio = CachedNetwork();
    try {
      var res = await dio.get(
          url,
          BaseOptions(headers: {
            ...HtmangaNetwork.headers,
            if (headers != null) ...headers
          }),
          cookieJar: SingleInstanceCookieJar.instance,
          expiredTime: cache ? CacheExpiredTime.short : CacheExpiredTime.no);
      if (res.url.contains('users-login') ||
          HtMangaParser.requiresLogin(res.data)) {
        return Res(null, errorMessage: "未登录或登录到期".tl);
      }
      return Res(res.data);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const Res(null, errorMessage: "连接超时");
      } else {
        return Res(null, errorMessage: e.toString());
      }
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  ///基本的Post请求
  Future<Res<String>> post(String url, String data) async {
    var dio = logDio(BaseOptions(headers: {
      ...headers,
      "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"
    }, responseType: ResponseType.plain));
    dio.interceptors.add(CookieManagerSql(SingleInstanceCookieJar.instance!));
    try {
      var res = await dio.post(url, data: data);
      return Res(res.data);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const Res(null, errorMessage: "连接超时");
      } else {
        return Res(null, errorMessage: e.toString());
      }
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  ///登录
  Future<Res<bool>> login(String account, String pwd, [bool saveData = true]) async {
    final uri = Uri.parse(baseUrl);
    final cookieJar = SingleInstanceCookieJar.instance!;
    final previousCookies = cookieJar.loadForRequest(uri);
    final previousUserAgent = htManga.data['userAgent'];
    var imported = false;
    try {
      final session = await htMangaWebLogin(baseUrl, account, pwd);
      if (session == null) {
        return Res.error('已取消登录'.tl);
      }
      imported = true;
      cookieJar.deleteUri(uri);
      cookieJar.saveFromResponse(
          uri,
          session.cookies.entries
              .map((entry) => Cookie(entry.key, entry.value)
                ..domain = uri.host
                ..path = '/'
                ..secure = uri.scheme == 'https')
              .toList());
      htManga.data['userAgent'] = session.userAgent;

      // Verify through the app's HTTP client, not just the WebView's page title.
      final favorites = await get('$baseUrl/users-users_fav.html', cache: false);
      if (favorites.error) throw StateError(favorites.errorMessage!);
      if (!HtMangaParser.isAuthenticated(favorites.data)) {
        throw StateError('未登录或登录到期'.tl);
      }
      final comics = await getComicList('$baseUrl/albums.html', 1);
      if (comics.error) throw StateError(comics.errorMessage!);
      if (comics.data.isEmpty) throw StateError('未获取到漫画'.tl);
      return const Res(true);
    } catch (e) {
      if (imported) {
        cookieJar.deleteUri(uri);
        cookieJar.saveFromResponse(uri, previousCookies);
        if (previousUserAgent == null) {
          htManga.data.remove('userAgent');
        } else {
          htManga.data['userAgent'] = previousUserAgent;
        }
      }
      return Res.error(e.toString());
    }
  }

  Future<Res<bool>> loginFromAppdata() async {
    var res = await htManga.reLogin();
    return res ? const Res(true) : const Res.error("error");
  }

  Future<Res<HtHomePageData>> getHomePage() async {
    var res = await get(baseUrl, cache: false);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var document = parse(res.data);
      var titles = document.querySelectorAll("div.title_sort");
      var comicBlocks = document.querySelectorAll("div.bodywrap");
      Map<String, String> titleRes = {};
      for (var title in titles) {
        var text = title.querySelector("div.title_h2")!.text;
        text = text.replaceAll("\n", "").removeAllBlank;
        var link = title.querySelector("div.r > a")!.attributes["href"]!;
        link = HtMangaParser.resolveUrl(link, baseUrl);
        titleRes[text] = link;
      }
      var comicsRes = <List<HtComicBrief>>[];
      for (var block in comicBlocks) {
        var cs = block.querySelectorAll("div.gallary_wrap > ul.cc > li");
        var comics = <HtComicBrief>[];
        for (var c in cs) {
          var link = c.querySelector("div.pic_box > a")!.attributes["href"]!;
          var id = RegExp(r"(?<=-aid-)[0-9]+").firstMatch(link)![0]!;
          var image =
              c.querySelector("div.pic_box > a > img")!.attributes["src"]!;
          image = HtMangaParser.resolveUrl(image, baseUrl);
          var name = c.querySelector("div.info > div.title > a")!.text;
          var infoCol = c.querySelector("div.info > div.info_col")!.text;
          var lr = infoCol.split(",");
          var time = lr[0];
          var pagesStr = "";
          for (int i = 0; i < lr[1].length; i++) {
            if (lr[1][i].isNum) {
              pagesStr += lr[1][i];
            }
          }
          var pages = int.parse(pagesStr);
          try {
            final chapterCount = HtMangaParser.chapterCount(infoCol);
            comics.add(HtComicBrief(
                name, time, image, id, chapterCount == null ? pages : 0,
                chapterCount: chapterCount));
          } finally {}
        }
        comicsRes.add(comics);
      }
      if (comicsRes.length != titleRes.length) {
        throw Exception("漫画块数量和标题数量不相等");
      }
      return Res(HtHomePageData(comicsRes, titleRes));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyze", "$e\n$s");
      return Res(null, errorMessage: "解析失败: $e");
    }
  }

  /// 获取给定漫画列表页面的漫画
  Future<Res<List<HtComicBrief>>> getComicList(String url, int page, {bool searchPage = false}) async {
    if (page != 1) {
      if (url.contains("search")) {
        url = "$url&p=$page";
      } else if (url.contains("ranking")) {
        url = url.replaceAll("ranking", "ranking-page-$page");
      } else {
        if (!url.contains("-")) {
          url = url.replaceAll(".html", "-.html");
        }
        url = url.replaceAll("index", "");
        var lr = url.split("albums-");
        lr[1] = "index-page-$page${lr[1]}";
        url = "${lr[0]}albums-${lr[1]}";
      }
    }
    var res = await get(url, cache: false);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var document = parse(res.data);
      var comics = <HtComicBrief>[];
      for (var comic in document
          .querySelectorAll("div.grid div.gallary_wrap > ul.cc > li")) {
        try {
          var link =
              comic.querySelector("div.pic_box > a")!.attributes["href"]!;
          var id = RegExp(r"(?<=-aid-)[0-9]+").firstMatch(link)![0]!;
          var image =
              comic.querySelector("div.pic_box > a > img")!.attributes["src"]!;
          image = HtMangaParser.resolveUrl(image, baseUrl);
          var name = comic
              .querySelector("div.info > div.title > a")!
              .attributes["title"]
              ?.replaceAll("<em>", "")
              .replaceAll("</em>", "");
          name = name ??
              comic
                  .querySelector("div.info > div.title > a")!
                  .text
                  .replaceAll("<em>", "")
                  .replaceAll("</em>", "");
          var infoCol = comic.querySelector("div.info > div.info_col")!.text;
          var lr = infoCol.split("，");
          var time = lr[1].removeAllBlank;
          time = time.replaceAll("\n", "");
          var pagesStr = "";
          for (int i = 0; i < lr[0].length; i++) {
            if (lr[0][i].isNum) {
              pagesStr += lr[0][i];
            }
          }
          var pages = pagesStr == "" ? 0 : int.parse(pagesStr);
          final chapterCount = HtMangaParser.chapterCount(infoCol);
          comics.add(HtComicBrief(
              name, time, image, id, chapterCount == null ? pages : 0,
              chapterCount: chapterCount));
        } catch (e) {
          continue;
        }
      }
      int pages;
      try {
        if(searchPage){
          var result = int.parse(document.querySelectorAll("p.result > b")[0].text.nums);
          var comicsOnePage = document.querySelectorAll("div.grid div.gallary_wrap > ul.cc > li").length;
          pages = result ~/ comicsOnePage + 1;
        }else{
          var pagesLink = document.querySelectorAll("div.f_left.paginator > a");
          pages = int.parse(pagesLink.last.text);
        }
      } catch (e) {
        pages = 1;
      }
      return Res(comics, subData: pages);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<List<HtComicBrief>>> search(String keyword, int page) {
    if (keyword != "") {
      appdata.searchHistory.remove(keyword);
      appdata.searchHistory.add(keyword);
      appdata.writeHistory();
    }
    Future.delayed(const Duration(milliseconds: 300),
            () => StateController.find<PreSearchController>().update())
        .onError((error, stackTrace) => null);
    return getComicList(
        "$baseUrl/search/?q=${Uri.encodeComponent(keyword)}&f=_all&s=create_time_DESC&syn=yes",
        page, searchPage: true);
  }

  /// 获取漫画详情, subData为第一页的缩略图
  Future<Res<HtComicInfo>> getComicInfo(String id) async {
    var res =
        await get("$baseUrl/photos-index-page-1-aid-$id.html", cache: false);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var document = parse(res.data);
      var name = document.querySelector("div.userwrap > h2")!.text;
      var coverPath = document
          .querySelector(
              "div.userwrap > div.asTB > div.asTBcell.uwthumb > img")!
          .attributes["src"]!;
      coverPath = HtMangaParser.resolveUrl(coverPath, baseUrl);
      var labels = document.querySelectorAll("div.asTBcell.uwconn > label");
      var category = labels[0].text.split("：")[1];
      var pages = int.tryParse(RegExp(r"[頁页][數数]\s*[:：]\s*(\d+)")
                  .firstMatch(labels.map((label) => label.text).join('\n'))?[1] ??
              '') ??
          0;
      var tagsDom = document.querySelectorAll("div.asTBcell.uwconn a.tagshow");
      var tags = <String, String>{};
      for (var tag in tagsDom) {
        var link = tag.attributes["href"]!;
        tags[tag.text] = link;
      }
      var description = document.querySelector("div.asTBcell.uwconn > p")!.text;
      var uploader =
          document.querySelector("div.asTBcell.uwuinfo > a > p")!.text;
      var avatar = document
          .querySelector("div.asTBcell.uwuinfo > a > img")!
          .attributes["src"]!;
      avatar = HtMangaParser.resolveUrl(avatar, '$baseUrl/');
      var uploadNum = int.parse(
          document.querySelector("div.asTBcell.uwuinfo > p > font")!.text);
      var photosDom = document.querySelectorAll("div.pic_box.tb > a > img");
      var photos = List<String>.generate(photosDom.length,
          (index) => HtMangaParser.resolveUrl(
              photosDom[index].attributes['src']!, baseUrl));
      final chapters = HtMangaParser.chapters(res.data);
      final series = document.querySelector('#sr_pub');
      if (series != null) {
        // A collection has its own ID, but its images belong to the chapter IDs.
        // The website paginates the directory separately from image thumbnails.
        final total = int.tryParse(series.attributes['data-total'] ?? '') ??
            chapters.length;
        final perPage = int.tryParse(series.attributes['data-per'] ?? '') ?? 12;
        if (perPage <= 0) throw const FormatException('无效的章节分页');
        final template = series.attributes['data-pageurl'] ??
            '/photos-index-aid-$id-page-[#page#].html';
        for (var page = 2; page <= (total / perPage).ceil(); page++) {
          final path = template
              .replaceAll('[#page#]', '$page')
              .replaceAll(RegExp('%5B%23page%23%5D', caseSensitive: false), '$page');
          final response = await get(HtMangaParser.resolveUrl(path, baseUrl),
              cache: false);
          if (response.error) return Res.fromErrorRes(response);
          chapters.addAll(HtMangaParser.chapters(response.data));
        }
        if (chapters.isEmpty || chapters.length < total) {
          throw const FormatException('未获取到完整的漫画章节');
        }
      }
      return Res(
          HtComicInfo(id, coverPath, name, category, pages, tags, description,
              uploader, avatar, uploadNum, photos,
              chapters: chapters));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<List<String>>> getThumbnails(String id, int page) async {
    var res = await get("$baseUrl/photos-index-page-$page-aid-$id.html");
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var document = parse(res.data);
      var photosDom = document.querySelectorAll("div.pic_box.tb > a > img");
      var photos = List<String>.generate(photosDom.length,
          (index) => HtMangaParser.resolveUrl(
              photosDom[index].attributes['src']!, baseUrl));
      return Res(photos);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<List<String>>> getImages(String id) async {
    var res = await get("$baseUrl/photos-gallery-aid-$id.html", cache: false);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      return Res(HtMangaParser.galleryImages(res.data, baseUrl));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  /// 获取收藏夹
  ///
  /// 返回Map, 值为收藏夹名，键为ID
  Future<Res<Map<String, String>>> getFolders() async {
    var res = await get(
        "$baseUrl/users-addfav-id-210814.html",
        cache: false);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var document = parse(res.data);
      var data = <String, String>{};
      for (var option in document.querySelectorAll("option")) {
        if (option.attributes["value"] == "") continue;
        data[option.attributes["value"]!] = option.text;
      }
      return Res(data);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<bool> createFolder(String name) async => !(await post(
          "$baseUrl/users-favc_save-id.html",
          "favc_name=${Uri.encodeComponent(name)}"))
      .error;

  Future<bool> deleteFolder(String id) async => !(await get(
          "$baseUrl/users-favclass_del-id-$id.html"
          "?ajax=true&_t=${Random.secure().nextDouble()}",
          cache: false))
      .error;

  Future<Res<bool>> addFavorite(String comicId, String folderId) async {
    var res = await post(
        "$baseUrl/users-save_fav-id-$comicId.html", "favc_id=$folderId");
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    return const Res(true);
  }

  Future<Res<bool>> delFavorite(String favoriteId) async {
    var res = await get(
      "$baseUrl/users-fav_del-id-$favoriteId.html?"
      "ajax=true&_t=${Random.secure().nextDouble()}",
      cache: false,
    );
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    return const Res(true);
  }

  ///获取收藏夹中的漫画
  Future<Res<List<HtComicBrief>>> getFavoriteFolderComics(
      String folderId, int page) async {
    var res = await get(
      "$baseUrl/users-users_fav-page-$page-c-$folderId.html",
      cache: false,
    );
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var document = parse(res.data);
      var comics = <HtComicBrief>[];
      for (var comic in document.querySelectorAll("div.asTB")) {
        var cover = comic
            .querySelector("div.asTBcell.thumb > div > img")!
            .attributes["src"]!;
        cover = HtMangaParser.resolveUrl(cover, baseUrl);
        var time = comic
            .querySelector("div.box_cel.u_listcon > p.l_catg > span")!
            .text
            .replaceAll("創建時間：", "");
        var name =
            comic.querySelector("div.box_cel.u_listcon > p.l_title > a")!.text;
        var link = comic
            .querySelector("div.box_cel.u_listcon > p.l_title > a")!
            .attributes["href"]!;
        var id = RegExp(r"(?<=-aid-)[0-9]+").firstMatch(link)![0]!;
        var info =
            comic.querySelector("div.box_cel.u_listcon > p.l_detla")?.text ?? "";
        // 页数可能缺失或使用不同的文字、冒号和空白，不应导致整个收藏夹加载失败。
        var pages = int.tryParse(RegExp(r"[頁页][數数]\s*[:：]\s*([0-9]+)")
                    .firstMatch(info)?[1] ??
                "") ??
            0;
        var delUrl = comic
            .querySelector("div.box_cel.u_listcon > p.alopt > a")!
            .attributes["onclick"]!;
        var favoriteId = RegExp(r"(?<=del-id-)[0-9]+").firstMatch(delUrl)![0];
        comics.add(HtComicBrief(name, time, cover, id, pages,
            favoriteId: favoriteId,
            chapterCount: HtMangaParser.chapterCount(info)));
      }
      int pages;
      try {
        var pagesLink = document.querySelectorAll("div.f_left.paginator > a");
        pages = int.parse(pagesLink.last.text);
      } catch (e) {
        pages = page;
      }
      return Res(comics, subData: pages);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }
}
