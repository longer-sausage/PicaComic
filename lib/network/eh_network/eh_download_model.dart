import 'package:dio/dio.dart';
import 'dart:async';
import 'dart:isolate';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/eh_network/eh_models.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/file_downloader.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:zip_flutter/zip_flutter.dart';
import 'dart:io';
import '../../tools/io_tools.dart';
import '../../tools/translations.dart';
import '../download.dart';
import 'eh_main_network.dart';
import 'get_gallery_id.dart';

class DownloadedGallery extends DownloadedItem {
  Gallery gallery;
  double? size;
  DownloadedGallery(this.gallery, this.size);

  @override
  Map<String, dynamic> toJson() => {"gallery": gallery.toJson(), "size": size};
  DownloadedGallery.fromJson(Map<String, dynamic> map)
      : gallery = Gallery.fromJson(map["gallery"]),
        size = map["size"];

  @override
  DownloadType get type => DownloadType.ehentai;

  @override
  List<int> get downloadedEps => [0];

  @override
  List<String> get eps => ["EP 1"];

  @override
  String get name {
    if (appdata.settings[78] == "1") {
      return gallery.subTitle ?? gallery.title;
    } else {
      return gallery.title;
    }
  }

  @override
  String get id => getGalleryId(gallery.link);

  @override
  String get subTitle => gallery.uploader;

  @override
  double? get comicSize => size;

  @override
  set comicSize(double? value) {
    size = value;
  }

  List<String> _getTags() {
    var res = <String>[];
    for (final tags in gallery.tags.values) {
      res.addAll(tags);
    }
    return res;
  }

  @override
  List<String> get tags => _getTags();
}

///e-hentai的下载进程模型
class EhDownloadingItem extends DownloadingItem {
  EhDownloadingItem(this.gallery, super.whenFinish, super.onError,
      super.updateInfo, super.id, this.downloadType,
      {super.type = DownloadType.ehentai});

  ///画廊模型
  final Gallery gallery;

  final int downloadType;

  @override
  Map<String, String> get headers => {
        "Cookie": EhNetwork().cookiesStr,
        "User-Agent": webUA,
        "Referer": EhNetwork().ehBaseUrl,
      };

  @override
  String get cover =>
      gallery.coverPath.replaceFirst('s.exhentai.org', 'ehgt.org');

  @override
  String get title => gallery.title;

  @override
  Future<Map<int, List<String>>> getLinks() async {
    return {
      0: List.generate(
          (int.parse(gallery.maxPage)), (index) => (index + 1).toString())
    };
  }

  @override
  Stream<DownloadProgress> downloadImage(String link,
      {CancelToken? cancelToken}) {
    return ImageManager().getEhImageNew(gallery, int.parse(link), cancelToken);
  }

  @override
  Map<String, dynamic> toMap() => {
        "gallery": gallery.toJson(),
        "downloadType": downloadType,
        "_downloadLink": _downloadLink,
        "_currentBytes": _currentBytes,
        "_totalBytes": _totalBytes,
        ...super.toBaseMap()
      };

  @override
  Future<void> onStart() async {
    await super.onStart();
    // clear showKey and imageKey
    // imageKey is saved through the network cache mechanism
    gallery.auth?.remove("showKey");
    await CacheManager().deleteKeyword("exhentai.org");
    await CacheManager().deleteKeyword("e-hentai.org");
  }

  int? _currentBytes;

  int? _totalBytes;

  @override
  int get totalPages {
    if (downloadType == 0) {
      return super.totalPages;
    } else {
      return _totalBytes ?? 1;
    }
  }

  @override
  int get downloadedPages {
    if (downloadType == 0) {
      return super.downloadedPages;
    } else {
      return _currentBytes ?? 0;
    }
  }

  _IsolateDownloader? _downloader;

  bool _stop = false;

  String? _downloadLink;

  int _currentSpeed = 0;

  @override
  int get currentSpeed =>
      downloadType == 0 ? super.currentSpeed : _currentSpeed;

  int _archiveGeneration = 0;
  Future<void> _archiveStopped = Future.value();
  int _archiveConcurrency = 6;

  @override
  int get allowedLoadingNumber =>
      downloadType == 0 ? super.allowedLoadingNumber : _archiveConcurrency;

  @override
  void refreshConcurrency() {
    if (downloadType == 0) {
      super.refreshConcurrency();
    } else {
      _downloader?.updateConcurrency();
    }
  }

  @override
  start() async {
    if (downloadType == 0) {
      return super.start();
    } else {
      final generation = ++_archiveGeneration;
      _stop = false;
      try {
        await _archiveStopped;
        if (_stop || generation != _archiveGeneration) return;
        await onStart();
        if (_stop || generation != _archiveGeneration) return;
        await downloadCover();
        if (_stop || generation != _archiveGeneration) return;
        if (gallery.auth?["archiveDownload"] == null) {
          throw "No archive download link";
        }
        if (_downloadLink == null) {
          var res = await EhNetwork().getArchiveDownloadLink(
              gallery.auth!["archiveDownload"]!, downloadType);
          if (_stop || generation != _archiveGeneration) {
            return;
          }
          if (res.error) {
            throw res.errorMessage!;
          }
          _downloadLink = res.data;
        }
        _downloader = _IsolateDownloader(_downloadLink!, path,
            (current, total, speed, concurrency) {
          if (_stop || generation != _archiveGeneration) return;
          _currentBytes = current;
          _totalBytes = total;
          _currentSpeed = speed;
          _archiveConcurrency = concurrency;
          notifications.sendProgressNotification(current, total, '下载中'.tl,
              '${DownloadManager().downloading.length} Tasks');
          updateInfo?.call();
          if (current == total) {
            if (DownloadManager().downloading.firstOrNull != this) return;
            finish();
          }
        }, () {
          if (!_stop && generation == _archiveGeneration) onError?.call();
        });
        _downloader!.start();
      } catch (e, s) {
        if (_stop || generation != _archiveGeneration) return;
        log("$e\n$s", "Download", LogLevel.error);
        onError?.call();
        return;
      }
    }
  }

  void finish() async {
    onFinish?.call();
  }

  @override
  Future<void> pause() async {
    if (downloadType == 0) {
      super.pause();
      return;
    } else {
      _archiveGeneration++;
      _stop = true;
      _currentSpeed = 0;
      _archiveStopped = _downloader?.stop() ?? Future.value();
      await _archiveStopped;
    }
  }

  @override
  Future<void> stop() async {
    if (downloadType == 0) {
      super.stop();
      return;
    } else {
      _archiveGeneration++;
      _stop = true;
      _archiveStopped = _downloader?.stop() ?? Future.value();
      await _archiveStopped;
      if (directory == null) return;
      final comicDirectory = Directory(path);
      if (await comicDirectory.exists()) {
        await comicDirectory.delete(recursive: true);
      }
    }
  }

  EhDownloadingItem.fromMap(
      Map<String, dynamic> map,
      DownloadProgressCallback whenFinish,
      DownloadProgressCallback whenError,
      DownloadProgressCallbackAsync updateInfo,
      String id)
      : gallery = Gallery.fromJson(map["gallery"]),
        downloadType = map["downloadType"],
        _currentBytes = map["_currentBytes"],
        _totalBytes = map["_totalBytes"],
        _downloadLink = map["_downloadLink"],
        super.fromMap(map, whenFinish, whenError, updateInfo);

  @override
  FutureOr<DownloadedItem> toDownloadedItem() async {
    return DownloadedGallery(gallery, await getFolderSize(Directory(path)));
  }
}

class _IsolateDownloader {
  final String url;

  final String savePath;

  ReceivePort? port;

  SendPort? sendPort;
  bool _stopped = false;
  bool _starting = false;
  final _terminated = Completer<void>();

  final void Function(int current, int total, int speed, int concurrency)
      updateInfo;

  final void Function() onError;

  _IsolateDownloader(this.url, this.savePath, this.updateInfo, this.onError);

  Isolate? isolate;

  Future<void> stop() {
    if (_terminated.isCompleted) return _terminated.future;
    _stopped = true;
    if (sendPort != null) {
      sendPort!.send('stop');
    } else if (!_starting && isolate == null) {
      _finish();
    }
    return _terminated.future;
  }

  void _finish() {
    isolate?.kill(priority: Isolate.immediate);
    isolate = null;
    port?.close();
    if (!_terminated.isCompleted) _terminated.complete();
  }

  void start() async {
    _starting = true;
    try {
      final proxy = await getProxy();
      if (_stopped) {
        _finish();
        return;
      }
      final receiving = port = ReceivePort();
      var total = 0;
      receiving.listen((message) {
        if (message is SendPort) {
          sendPort = message;
          if (_stopped) {
            message.send('stop');
          } else {
            updateConcurrency();
          }
        } else if (message is DownloadingStatus) {
          updateInfo(message.downloadedBytes, message.totalBytes + 1,
              message.bytesPerSecond, message.concurrency);
          total = message.totalBytes;
        } else if (message == "finish") {
          _finish();
          updateInfo(total + 1, total + 1, 0, 1);
        } else if (message is _DownloadException) {
          _finish();
          LogManager.addLog(LogLevel.error, "Download", message.message);
          if (!_stopped) onError();
        } else if (message == 'stopped') {
          _finish();
        } else if (message == null || message is List) {
          _finish();
          if (!_stopped) {
            Log.error(
                'Download', 'Archive worker exited unexpectedly: $message');
            onError();
          }
        }
      });
      isolate = await Isolate.spawn<_DownloadData>(
          run,
          _DownloadData(
              receiving.sendPort,
              url,
              savePath,
              proxy,
              appdata.appSettings.adaptiveDownloadConcurrency,
              appdata.appSettings.downloadConcurrency),
          onError: receiving.sendPort,
          onExit: receiving.sendPort);
      if (_terminated.isCompleted) _finish();
    } catch (error, stack) {
      _finish();
      if (!_stopped) {
        Log.error('Download', '$error\n$stack');
        onError();
      }
    } finally {
      _starting = false;
    }
  }

  void updateConcurrency() {
    sendPort?.send({
      'adaptive': appdata.appSettings.adaptiveDownloadConcurrency,
      'maxConcurrent': appdata.appSettings.downloadConcurrency,
    });
  }

  static void run(_DownloadData data) async {
    var receivePort = ReceivePort();

    final sendPort = data.port;

    sendPort.send(receivePort.sendPort);

    final url = data.url;

    final savePath = data.savePath;

    FileDownloader? task;
    var stopped = false;

    receivePort.listen((message) {
      if (message == "stop") {
        stopped = true;
        if (task == null) {
          Isolate.exit(sendPort, 'stopped');
        } else {
          task!.stop().then((_) => Isolate.exit(sendPort, 'stopped'));
        }
      } else if (message is Map) {
        task?.updateConcurrency(
            adaptive: message['adaptive'] as bool,
            maxConcurrent: message['maxConcurrent'] as int);
      }
    });

    Future.sync(() async {
      task = FileDownloader(url, "$savePath/temp.zip", data.proxy,
          adaptive: data.adaptive, maxConcurrent: data.maxConcurrent);

      try {
        await for (var status in task!.start()) {
          sendPort.send(status);
        }
        if (stopped) return;
        ZipFile.openAndExtract("$savePath/temp.zip", savePath);
        var files = Directory(savePath).listSync();
        files.sort((a, b) => a.path.compareTo(b.path));
        int index = 0;
        for (var entry in files) {
          if (entry is File) {
            var name = entry.path.split(pathSep).last;
            if (name.endsWith(".zip")) {
              entry.deleteSync();
            } else if (!name.contains("cover")) {
              var baseName = index.toString();
              index++;
              var ext = name.split(".").last;
              entry.renameSync("$savePath/$baseName.$ext");
            }
          }
        }
        sendPort.send("finish");
      } catch (e, s) {
        sendPort.send(_DownloadException("$e\n$s"));
      }
    });
  }
}

class _DownloadData {
  final SendPort port;
  final String url;
  final String savePath;
  final String? proxy;
  final bool adaptive;
  final int maxConcurrent;

  const _DownloadData(this.port, this.url, this.savePath, this.proxy,
      this.adaptive, this.maxConcurrent);
}

class _DownloadException {
  final String message;

  const _DownloadException(this.message);
}
