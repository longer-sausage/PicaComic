import 'package:dio/dio.dart';
import 'dart:async';
import 'dart:io';
import 'package:pica_comic/network/htmanga_network/htmanga_main_network.dart';
import 'package:pica_comic/network/htmanga_network/models.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/network/download.dart';
import '../../foundation/image_manager.dart';
import '../../tools/io_tools.dart';

class DownloadedHtComic extends DownloadedItem {
  DownloadedHtComic(this.comic, this.size, [List<int>? downloadedChapters])
      : downloadedChapters = downloadedChapters ??
            List.generate(comic.isCollection ? comic.chapters.length : 1,
                (index) => index);

  HtComicInfo comic;

  double? size;

  final List<int> downloadedChapters;

  @override
  double? get comicSize => size;

  @override
  List<int> get downloadedEps => downloadedChapters;

  @override
  List<String> get eps =>
      comic.isCollection ? comic.chapters.values.toList() : ["EP 1"];

  @override
  String get id => "Ht${comic.id}";

  @override
  String get name => comic.name;

  @override
  String get subTitle => comic.uploader;

  @override
  DownloadType get type => DownloadType.htmanga;

  @override
  Map<String, dynamic> toJson() => {
        "comic": comic.toJson(),
        "size": size,
        "downloadedChapters": downloadedChapters,
      };

  DownloadedHtComic.fromJson(Map<String, dynamic> json)
      : this(HtComicInfo.fromJson(json["comic"]), json["size"],
            (json["downloadedChapters"] as List?)?.cast<int>());

  @override
  set comicSize(double? value) => size = value;

  @override
  List<String> get tags => comic.tags.keys.toList();
}

class DownloadingHtComic extends DownloadingItem {
  DownloadingHtComic(
      this.comic, super.whenFinish, super.whenError, super.updateInfo, super.id,
      {List<int>? downloadEps, super.type = DownloadType.htmanga})
      : _downloadEps = downloadEps ??
            List.generate(comic.isCollection ? comic.chapters.length : 1,
                (index) => index);

  final HtComicInfo comic;

  final List<int> _downloadEps;

  @override
  bool get haveEps => comic.isCollection;

  @override
  Map<String, String> get headers => HtmangaNetwork.headers;

  String _getCover() {
    var uri = comic.coverPath;
    if (uri.contains("https:") && !uri.contains("https://")) {
      uri = uri.replaceFirst("https:", "https://");
    }
    return uri;
  }

  @override
  String get cover => _getCover();

  @override
  String get title => comic.name;

  @override
  Future<Map<int, List<String>>> getLinks() async {
    if (comic.isCollection) {
      return loadDownloadChapters(
          Iterable.generate(comic.chapters.length, (index) => index + 1)
              .where((ep) => _downloadEps.contains(ep - 1)), (ep) async {
        final chapterId = comic.chapters.keys.elementAt(ep - 1);
        return (await HtmangaNetwork().getImages(chapterId)).data;
      });
    }
    var res = await HtmangaNetwork().getImages(comic.id);
    return {0: res.data};
  }

  @override
  Stream<DownloadProgress> downloadImage(String link,
      {CancelToken? cancelToken}) {
    return ImageManager().getImage(link, HtmangaNetwork.headers, cancelToken);
  }

  @override
  Map<String, dynamic> toMap() => {
        "comic": comic.toJson(),
        "downloadEps": _downloadEps,
        ...super.toBaseMap()
      };

  DownloadingHtComic.fromMap(
      Map<String, dynamic> map,
      DownloadProgressCallback whenFinish,
      DownloadProgressCallback whenError,
      DownloadProgressCallbackAsync updateInfo,
      String id)
      : comic = HtComicInfo.fromJson(map["comic"]),
        _downloadEps = (map["downloadEps"] as List?)?.cast<int>() ?? [0],
        super.fromMap(map, whenFinish, whenError, updateInfo);

  @override
  FutureOr<DownloadedItem> toDownloadedItem() async {
    final previous = await DownloadManager().getComicOrNull(id);
    final downloaded = {...?previous?.downloadedEps, ..._downloadEps}.toList()
      ..sort();
    return DownloadedHtComic(
      comic,
      await getFolderSize(Directory(path)),
      downloaded,
    );
  }
}
