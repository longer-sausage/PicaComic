// Shared workload for desktop tests and the isolated Android benchmark app.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

class _Download extends DownloadingItem {
  final String folder;
  _Download(this.folder, List<String> urls, Completer<void> done)
      : super(done.complete, () => done.completeError('Download failed'), null,
            'heat-benchmark',
            type: DownloadType.nhentai) {
    directory = 'pages';
    links = {0: urls};
  }
  @override
  String get path => folder;
  @override
  String get title => 'Benchmark';
  @override
  String get cover => '';
  @override
  Future<void> downloadCover() async {}
  @override
  Future<Map<int, List<String>>> getLinks() async => links!;
  @override
  Map<String, dynamic> toMap() => toBaseMap();
  @override
  DownloadedItem toDownloadedItem() => throw UnimplementedError();
  @override
  Stream<DownloadProgress> downloadImage(String url,
          {CancelToken? cancelToken}) =>
      ImageManager().getImage(url, null, cancelToken);
}

Future<Map<String, Object>> runDownloadHeatBenchmark() async {
  if (Platform.isWindows) {
    open.overrideFor(
        OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  }
  const concurrency = int.fromEnvironment('BENCH_CONCURRENCY', defaultValue: 6);
  const count = 120;
  const seededFiles = 1800;
  final directory = await Directory.systemTemp.createTemp('pica-heat-bench-');
  App.cachePath = directory.path;
  App.dataPath = directory.path;
  final cacheDir = Directory('${directory.path}/cache/seed')
    ..createSync(recursive: true);
  final db = sqlite3.open('${directory.path}/cache.db');
  db.execute(
      'CREATE TABLE cache (key TEXT PRIMARY KEY NOT NULL, dir TEXT NOT NULL, '
      'name TEXT NOT NULL, expires INTEGER NOT NULL, type TEXT)');
  final expires =
      DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch;
  db.execute('BEGIN');
  for (var i = 0; i < seededFiles; i++) {
    File('${cacheDir.path}/$i').writeAsBytesSync(Uint8List(1024));
    db.execute('INSERT INTO cache VALUES (?, ?, ?, ?, NULL)',
        ['seed-$i', 'seed', '$i', expires]);
  }
  db.execute('COMMIT');
  db.dispose();
  final cache = CacheManager();
  while (cache.currentSize < seededFiles * 1024) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  SingleInstanceCookieJar('${directory.path}/cookies.db');
  AppTranslation.translations = {};
  appdata.settings[58] = '0';
  appdata.settings[79] = '$concurrency';
  appdata.settings[90] = '0';
  final image = Uint8List(256 * 1024);
  image.setAll(0, [137, 80, 78, 71, 13, 10, 26, 10]);
  for (var i = 8; i < image.length; i++) {
    image[i] = i % 251;
  }
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var requests = 0;
  server.listen((request) async {
    requests++;
    request.response.headers.contentType = ContentType('image', 'png');
    request.response.contentLength = image.length;
    await Future<void>.delayed(const Duration(milliseconds: 25));
    request.response.add(image);
    await request.response.close();
  });
  final done = Completer<void>();
  final item = _Download(
      '${directory.path}/pages',
      List.generate(count, (i) => 'http://127.0.0.1:${server.port}/$i.png'),
      done);
  DownloadManager().downloading.add(item);
  final cpuBefore = await _cpuMicros();
  final watch = Stopwatch()..start();
  try {
    item.start();
    await done.future.timeout(const Duration(minutes: 3));
    watch.stop();
    // Include background maintenance that used to outlive page completion.
    await Future<void>.delayed(const Duration(seconds: 2));
    final cpuMicros = await _cpuMicros() - cpuBefore;
    final expectedHash = sha256.convert(image).toString();
    for (var i = 0; i < count; i++) {
      final file = File('${item.path}/$i.png');
      if (await file.length() != image.length ||
          sha256.convert(await file.readAsBytes()).toString() != expectedHash) {
        throw StateError('Downloaded page $i is corrupt');
      }
    }
    if (requests != count) {
      throw StateError('Expected $count requests, got $requests');
    }
    return {
      'concurrency': concurrency,
      'seededFiles': seededFiles,
      'pages': count,
      'bytes': count * image.length,
      'elapsedMs': watch.elapsedMilliseconds,
      'cpuMicros': cpuMicros,
      'rssBytes': ProcessInfo.currentRss,
      'cacheBytes': cache.currentSize,
      'temporaryDirectory': directory.path,
    };
  } finally {
    item.pause();
    DownloadManager().downloading.clear();
    await server.close(force: true);
    ImageManager().dio.close(force: true);
    // SQLite stays open for the singleton's lifetime. The caller can remove
    // the printed temporary directory after this process exits.
  }
}

Future<int> _cpuMicros() async {
  if (Platform.isWindows) {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      '(Get-Process -Id $pid).TotalProcessorTime.Ticks'
    ]);
    return int.parse(result.stdout.toString().trim()) ~/ 10;
  }
  if (Platform.isLinux || Platform.isAndroid) {
    final stat = await File('/proc/self/stat').readAsString();
    final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
    // Linux /proc uses USER_HZ (100 on Android), independent of CPU frequency.
    return (int.parse(fields[11]) + int.parse(fields[12])) * 10000;
  }
  return 0;
}
