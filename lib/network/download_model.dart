import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/file_type.dart';
import 'package:pica_comic/tools/io_extensions.dart';
import 'package:pica_comic/tools/translations.dart';

import '../base.dart';
import 'app_dio.dart';
import 'download.dart';
import 'download_scheduler.dart';

abstract class DownloadedItem {
  ///漫画源
  DownloadType get type;

  ///漫画名
  String get name;

  ///章节
  List<String> get eps;

  ///已下载的章节
  List<int> get downloadedEps;

  ///标识符
  String get id;

  ///副标题, 通常为作者
  String get subTitle;

  ///大小
  double? get comicSize;

  ///下载的时间
  DateTime? time;

  /// tags
  List<String> get tags;

  Map<String, dynamic> toJson();

  set comicSize(double? value);

  String? directory;
}

enum DownloadType {
  picacg,
  ehentai,
  jm,
  hitomi,
  htmanga,
  nhentai,
  other,
  favorite;

  ComicType toComicType() => switch (this) {
        picacg => ComicType.picacg,
        ehentai => ComicType.ehentai,
        jm => ComicType.jm,
        hitomi => ComicType.hitomi,
        htmanga => ComicType.htManga,
        nhentai => ComicType.nhentai,
        other => ComicType.other,
        favorite => ComicType.other,
      };
}

typedef DownloadProgressCallback = void Function();

typedef DownloadProgressCallbackAsync = Future<void> Function();

/// Fetch chapter metadata with bounded concurrency while retaining comic order.
Future<Map<int, List<String>>> loadDownloadChapters(
    Iterable<int> chapters, Future<List<String>> Function(int) load) async {
  final ordered = chapters.toSet().toList();
  final results = <int, List<String>>{};
  var next = 0;
  Future<void> worker() async {
    while (next < ordered.length) {
      final ep = ordered[next++];
      results[ep] = await load(ep);
    }
  }

  await Future.wait([
    for (var i = 0; i < 3 && i < ordered.length; i++) worker(),
  ]);
  return {for (final ep in ordered) ep: results[ep]!};
}

abstract class DownloadingItem with _TransferSpeedMixin {
  ///完成时调用
  final DownloadProgressCallback? onFinish;

  ///出现错误时调用
  final DownloadProgressCallback? onError;

  ///更新下载信息
  final DownloadProgressCallbackAsync? updateInfo;

  ///标识符, 对于哔咔和eh, 直接使用其提供的漫画id, 禁漫开头加jm, hitomi开头加hitomi
  final String id;

  ///类型
  DownloadType type;

  /// run function start will cause this increasing by 1
  ///
  /// this is used for preventing running multiple downloading function at the same time
  int _runtimeKey = 0;

  int _retryTimes = 0;
  bool _paused = true;

  String? directory;

  String get path {
    var downloadPath = DownloadManager().path!;
    return "$downloadPath/$directory";
  }

  /// headers for downloading cover
  Map<String, String> get headers => {};

  int _downloadedNum = 0;

  int _downloadingEp = 0;

  /// index of downloading episode
  ///
  /// Attention, this is used for array indexing, so it starts with 0
  int get downloadingEp => _downloadingEp;

  int index = 0;

  /// all image urls
  Map<int, List<String>>? links;

  int get allowedLoadingNumber =>
      _scheduler?.concurrency ??
      (appdata.appSettings.adaptiveDownloadConcurrency
          ? AdaptiveDownloadConcurrency.initialConcurrency
          : appdata.appSettings.downloadConcurrency);

  int get activeDownloads => _scheduler?.activeCount ?? 0;

  @override
  void onNextSecond(Timer t) {
    super.onNextSecond(t);
    notifications.sendProgressNotification(downloadedPages, totalPages,
        '下载中'.tl, '${downloadManager.downloading.length} Tasks');
  }

  void refreshConcurrency() => _scheduler?.refreshConcurrency();

  DownloadTaskScheduler<int>? _scheduler;
  AdaptiveDownloadConcurrency _adaptiveConcurrency =
      AdaptiveDownloadConcurrency();
  CancelToken? _coverCancelToken;
  final _completedTasks = <String>{};
  Future<void> _lastProgressSave = Future.value();

  DownloadingItem(this.onFinish, this.onError, this.updateInfo, this.id,
      {required this.type});

  Future<void> downloadCover() async {
    var file = File("$path/cover.jpg");
    if (file.existsSync()) {
      return;
    }
    final token = _coverCancelToken = CancelToken();
    final dio = logDio();
    try {
      final res = await dio.get<Uint8List>(cover,
          cancelToken: token,
          options: Options(responseType: ResponseType.bytes, headers: headers));
      if (token.isCancelled) return;
      await file.parent.create(recursive: true);
      await file.writeAsBytes(res.data!);
    } finally {
      dio.close();
      if (identical(_coverCancelToken, token)) _coverCancelToken = null;
    }
  }

  /// retry when error
  Future<void> retry() async {
    final currentKey = _runtimeKey;
    _retryTimes++;
    if (_retryTimes > 4) {
      onError?.call();
      _retryTimes = 0;
    } else {
      await Future.delayed(Duration(seconds: 2 << _retryTimes));
      if (currentKey == _runtimeKey) {
        start();
      }
    }
  }

  @mustCallSuper
  FutureOr<void> onStart() {
    if (directory == null) {
      if (DownloadManager().isExists(id)) {
        directory = DownloadManager().getDirectory(id);
      } else {
        directory = findValidDirectoryName(DownloadManager().path!, title);
        Directory(path).createSync(recursive: true);
      }
    }
  }

  void _saveProgress() {
    _lastProgressSave = Future<void>.sync(() async {
      await updateInfo?.call();
    }).catchError((Object error, StackTrace stack) {
      Log.error('Download', 'Failed to save progress: $error\n$stack');
    });
  }

  void _completePage(int ep, int page, int length) {
    _completedTasks.add('$ep:$page');
    // Keep the existing contiguous checkpoint format for older saved queues.
    // Later pages count toward progress immediately and survive pause/resume.
    while (index < length && _completedTasks.remove('$ep:$index')) {
      index++;
      _downloadedNum++;
    }
    _saveProgress();
  }

  Future<void> _downloadPage(
      int ep, int page, DownloadTaskContext task, int runtimeKey) async {
    DownloadProgress? result;
    var received = 0;
    await for (final progress
        in downloadImage(links![ep]![page], cancelToken: task.cancelToken)) {
      if (task.isCanceled) return;
      // A cached image is represented by a synthetic 1/1 progress event.
      if ((progress.data == null || received == 0) &&
          !(received == 0 && progress.finished && progress.currentBytes <= 1)) {
        task.receivedBytes(progress.currentBytes - received);
      }
      if (progress.currentBytes > received) received = progress.currentBytes;
      result = progress;
    }
    if (task.isCanceled) return;
    if (result == null || !result.finished) {
      throw const FileSystemException('Incomplete image download');
    }

    // Wait for stream completion: a final network chunk may precede cache flush
    // or image recombination even if its byte count already matches the total.
    final data = result.data;
    late List<int> header;
    if (data != null) {
      header = data;
    } else {
      final source = await result.getFile().open();
      try {
        header = await source.read(64);
      } finally {
        await source.close();
      }
    }
    if (header.isEmpty) throw const FileSystemException('Empty image');
    if (task.isCanceled) return;
    final target = haveEps ? '$path/$ep' : path;
    final file = File('$target/$page${detectFileType(header).ext}');
    final temporary = File('$target/.$page.$runtimeKey.part');
    try {
      if (data != null) {
        await temporary.writeAsBytes(data);
      } else {
        await result.getFile().copy(temporary.path);
      }
      if (task.isCanceled) return;
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  /// begin or continue downloading
  void start() async {
    if (!_paused) return;
    _runtimeKey++;
    _paused = false;
    var currentKey = _runtimeKey;
    var prepared = false;
    try {
      await onStart();
      if (_runtimeKey != currentKey) return;
      notifications.sendProgressNotification(downloadedPages, totalPages,
          "下载中".tl, "${downloadManager.downloading.length} Tasks");

      // get image links and cover
      final imageLinks = links ?? await getLinks();
      if (_runtimeKey != currentKey) return;
      links = imageLinks;
      await downloadCover();
      if (_runtimeKey != currentKey) return;
      prepared = true;
      _retryTimes = 0;
      runRecorder();

      // download images
      while (_downloadingEp < links!.length && currentKey == _runtimeKey) {
        int ep = links!.keys.elementAt(_downloadingEp);
        var urls = links![ep]!;
        await Directory(haveEps ? '$path/$ep' : path).create(recursive: true);
        if (currentKey != _runtimeKey) return;
        final scheduler = _scheduler = DownloadTaskScheduler<int>(
          tasks: Iterable.generate(urls.length - index, (i) => i + index)
              .where((page) => !_completedTasks.contains('$ep:$page')),
          adaptive: () => appdata.appSettings.adaptiveDownloadConcurrency,
          fixedConcurrency: () => appdata.appSettings.downloadConcurrency,
          controller: _adaptiveConcurrency,
          download: (page, task) => _downloadPage(ep, page, task, currentKey),
          onBytes: onData,
          onComplete: (page) {
            if (currentKey != _runtimeKey) return;
            _completePage(ep, page, urls.length);
          },
        );
        await scheduler.run();
        if (currentKey != _runtimeKey) return;
        _adaptiveConcurrency = scheduler.controller;
        _scheduler = null;
        // Restored out-of-order pages may fill the entire remaining episode.
        while (index < urls.length && _completedTasks.remove('$ep:$index')) {
          index++;
          _downloadedNum++;
        }
        index = 0;
        _downloadingEp++;
        _saveProgress();
      }

      // finish downloading
      if (_runtimeKey != currentKey) return;
      await _lastProgressSave;
      if (_runtimeKey != currentKey) return;
      if (DownloadManager().downloading.firstOrNull != this) return;
      _paused = true;
      stopRecorder();
      onFinish?.call();
      _stopAllTasks();
    } catch (e, s) {
      if (currentKey != _runtimeKey) return;
      _paused = true;
      stopRecorder();
      _stopAllTasks();
      LogManager.addLog(LogLevel.error, "Download", "$e\n$s");
      if (prepared) {
        onError?.call();
      } else {
        unawaited(retry());
      }
    }
  }

  void _stopAllTasks() {
    _scheduler?.cancel();
    _scheduler = null;
    _coverCancelToken?.cancel('Download stopped');
    _coverCancelToken = null;
  }

  /// pause downloading
  void pause() {
    _runtimeKey++;
    _paused = true;
    stopRecorder();
    notifications.endProgress();
    _stopAllTasks();
  }

  /// stop downloading
  void stop() {
    _runtimeKey++;
    _paused = true;
    stopRecorder();
    _stopAllTasks();
    notifications.endProgress();
    if (directory == null) return;
    if (downloadManager.isExists(id)) {
      if (links == null) return;
      var comicPath = "$path/";
      for (var ep in links!.keys.toList()) {
        var directory = Directory(comicPath + ep.toString());
        if (directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      }
    } else {
      var file = Directory(path);
      if (file.existsSync()) {
        file.delete(recursive: true);
      }
    }
  }

  Map<String, dynamic> toBaseMap() {
    Map<String, List<String>>? convertedData;
    if (links != null) {
      convertedData = {};
      links!.forEach((key, value) {
        convertedData![key.toString()] = value;
      });
    }

    return {
      "id": id,
      "type": type.index,
      "_downloadedNum": _downloadedNum,
      "_downloadingEp": _downloadingEp,
      "index": index,
      "links": convertedData,
      "directory": directory,
      "finishedTasks": _completedTasks.toList(),
      "taskKeyVersion": 2,
    };
  }

  Map<String, dynamic> toMap();

  DownloadingItem.fromMap(
      Map<String, dynamic> map, this.onFinish, this.onError, this.updateInfo)
      : id = map["id"],
        type = DownloadType.values[map["type"]],
        _downloadedNum = map["_downloadedNum"],
        _downloadingEp = map["_downloadingEp"],
        index = map["index"],
        links = null {
    var data = map["links"] as Map<String, dynamic>?;
    if (data != null) {
      links = {};
      data.forEach((key, value) {
        links![int.parse(key)] = List<String>.from(value);
      });
    }
    directory = map["directory"];
    final finished = Set<String>.from(map['finishedTasks'] ?? []);
    if (map['taskKeyVersion'] == 2) {
      _completedTasks.addAll(finished);
    } else if (links != null) {
      // Legacy task IDs concatenated episode and page without a separator.
      // Only the current episode could have outstanding finished pages.
      final eps = links!.keys.toList();
      if (_downloadingEp < eps.length) {
        final ep = eps[_downloadingEp];
        for (var page = index; page < links![ep]!.length; page++) {
          if (finished.contains('$ep$page')) _completedTasks.add('$ep:$page');
        }
      }
    }
  }

  /// get all image links
  ///
  /// key - episode number(starts with 1), value - image links in this episode
  ///
  /// if platform don't have episode, this only have one key: 0.
  Future<Map<int, List<String>>> getLinks();

  /// whether this platform have episode
  bool get haveEps =>
      type != DownloadType.ehentai &&
      type != DownloadType.hitomi &&
      type != DownloadType.htmanga &&
      type != DownloadType.nhentai;

  Stream<DownloadProgress> downloadImage(String link,
      {CancelToken? cancelToken});

  ///获取封面链接
  String get cover;

  ///总共的图片数量
  int get totalPages => links?.totalLength ?? 0;

  ///已下载的图片数量
  int get downloadedPages => _downloadedNum + _completedTasks.length;

  ///标题
  String get title;

  @override
  bool operator ==(Object other) {
    if (other is DownloadingItem) {
      return id == other.id;
    } else {
      return false;
    }
  }

  @override
  int get hashCode => id.hashCode;

  FutureOr<DownloadedItem> toDownloadedItem();

  @override
  String toString() {
    return "$id: $downloadedPages/$totalPages";
  }
}

abstract mixin class _TransferSpeedMixin {
  int _bytesSinceLastSecond = 0;

  int _currentSpeed = 0;

  int get currentSpeed => _currentSpeed;

  Timer? timer;

  void onData(int length) {
    if (timer == null) return;
    if (length > 0) _bytesSinceLastSecond += length;
  }

  void onNextSecond(Timer t) {
    _currentSpeed = _bytesSinceLastSecond;
    _bytesSinceLastSecond = 0;
    DownloadManager().notifyListeners();
  }

  void runRecorder() {
    if (timer != null) {
      timer!.cancel();
    }
    _bytesSinceLastSecond = _currentSpeed = 0;
    timer = Timer.periodic(const Duration(seconds: 1), onNextSecond);
  }

  void stopRecorder() {
    timer?.cancel();
    timer = null;
    _bytesSinceLastSecond = _currentSpeed = 0;
  }
}
