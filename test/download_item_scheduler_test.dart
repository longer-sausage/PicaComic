import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/tools/translations.dart';

class _PageDownload extends DownloadingItem {
  final String folder;
  final requests = <String>[];
  final streams = <String, StreamController<DownloadProgress>>{};
  final tokens = <CancelToken>[];

  _PageDownload(this.folder, Map<int, List<String>> pages,
      {DownloadProgressCallback? finished})
      : super(finished, null, null, 'test', type: DownloadType.nhentai) {
    directory = 'test';
    links = pages;
  }

  _PageDownload.restore(this.folder, Map<String, dynamic> saved)
      : super.fromMap(saved, null, null, null);

  @override
  String get path => folder;
  @override
  String get title => 'Test';
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
  Stream<DownloadProgress> downloadImage(String link,
      {CancelToken? cancelToken}) {
    requests.add(link);
    final stream = streams[link] = StreamController<DownloadProgress>();
    tokens.add(cancelToken!);
    unawaited(cancelToken.whenCancel.then((_) => stream.close()));
    return stream.stream;
  }

  Future<void> complete(String link, {String? cachedFile}) async {
    final bytes = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 0, 0]);
    streams[link]!.add(cachedFile == null
        ? DownloadProgress(bytes.length, bytes.length, link, '', bytes)
        : DownloadProgress(1, 1, link, cachedFile));
    await streams[link]!.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final items = <_PageDownload>[];

  Future<void> until(bool Function() ready) async {
    for (var i = 0; i < 200 && !ready(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(ready(), isTrue, reason: 'Download did not reach expected state');
  }

  setUpAll(() => AppTranslation.translations = {});

  setUp(() async {
    appdata.settings[79] = '2';
    appdata.settings[90] = '0';
    directory = await Directory.systemTemp.createTemp('pica-page-pool-');
  });

  tearDown(() async {
    for (final item in items) {
      item.pause();
    }
    items.clear();
    DownloadManager().downloading.clear();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
        directory.absolute.path.startsWith(Directory.systemTemp.absolute.path),
        isTrue);
    expect(directory.uri.pathSegments.where((s) => s.isNotEmpty).last,
        startsWith('pica-page-pool-'));
    await directory.delete(recursive: true);
  });

  test('later pages replenish slots and persist without waiting for page zero',
      () async {
    final finished = Completer<void>();
    final item = _PageDownload(
        directory.path,
        {
          0: ['slow', 'fast', 'next']
        },
        finished: finished.complete);
    items.add(item);
    DownloadManager().downloading.add(item);
    item.start();
    item.start();
    await until(() => item.requests.length == 2);
    await item.complete('fast');
    await until(() => item.requests.length == 3);
    expect(item.requests, ['slow', 'fast', 'next']);
    expect(item.downloadedPages, 1);
    expect(item.index, 0);
    final saved = item.toMap();
    expect(saved['finishedTasks'], ['0:1']);
    expect(File('${directory.path}/1.png').existsSync(), isTrue);
    final restored = _PageDownload.restore(directory.path, saved);
    items.add(restored);
    expect(restored.downloadedPages, 1);
    await item.complete('next');
    await item.complete('slow');
    await finished.future.timeout(const Duration(seconds: 3));
    expect(item.downloadedPages, 3);
    expect(item.toMap()['finishedTasks'], isEmpty);
  });

  test('resume skips saved pages and cannot collide episode/page task IDs',
      () async {
    final saved = {
      'id': 'test',
      'type': DownloadType.picacg.index,
      '_downloadedNum': 0,
      '_downloadingEp': 0,
      'index': 0,
      'directory': 'test',
      'links': {
        '1': List.generate(24, (i) => 'page-$i'),
        '12': ['other-0', 'other-1', 'other-2', 'other-3'],
      },
      'finishedTasks': ['1:23'],
      'taskKeyVersion': 2,
    };
    final item = _PageDownload.restore(directory.path, saved);
    items.add(item);
    item.start();
    await until(() => item.requests.length == 2);
    for (var page = 0; page < 23; page++) {
      await until(() => item.streams.containsKey('page-$page'));
      await item.complete('page-$page');
    }
    await until(() => item.streams.containsKey('other-0'));
    for (var page = 0; page < 3; page++) {
      await until(() => item.streams.containsKey('other-$page'));
      await item.complete('other-$page');
    }
    await until(() => item.streams.containsKey('other-3'));
    expect(item.requests, isNot(contains('page-23')));
    expect(item.requests, contains('other-3'));
  });

  test('legacy completion checkpoints migrate to separated task IDs', () {
    final item = _PageDownload.restore(directory.path, {
      'id': 'test',
      'type': DownloadType.nhentai.index,
      '_downloadedNum': 2,
      '_downloadingEp': 0,
      'index': 2,
      'directory': 'test',
      'links': {
        '0': ['0', '1', '2', '3']
      },
      'finishedTasks': ['03'],
    });
    items.add(item);
    expect(item.downloadedPages, 3);
    expect(item.toMap()['finishedTasks'], ['0:3']);
  });

  test('pause cancels requests and a late completion cannot write an image',
      () async {
    final item = _PageDownload(directory.path, {
      0: ['pending', 'other']
    });
    items.add(item);
    item.start();
    await until(() => item.requests.length == 2);
    item.pause();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(item.tokens.every((token) => token.isCancelled), isTrue);
    expect(item.downloadedPages, 0);
    expect(directory.listSync().whereType<File>(), isEmpty);
    expect(item.timer, isNull);
  });

  test(
      'chapter metadata uses at most three requests and preserves chapter order',
      () async {
    final pending = List.generate(5, (_) => Completer<List<String>>());
    final requests = <int>[];
    final loading = loadDownloadChapters([0, 1, 2, 3, 4], (ep) {
      requests.add(ep);
      return pending[ep].future;
    });
    expect(requests, [0, 1, 2]);
    pending[2].complete(['page-2']);
    await Future<void>.delayed(Duration.zero);
    expect(requests, [0, 1, 2, 3]);
    pending[3].complete(['page-3']);
    await Future<void>.delayed(Duration.zero);
    expect(requests, [0, 1, 2, 3, 4]);
    for (final ep in [4, 1, 0]) {
      pending[ep].complete(['page-$ep']);
    }
    final result = await loading;
    expect(result.keys, [0, 1, 2, 3, 4]);
    expect(result[4], ['page-4']);
  });

  test('a cached image is copied only after its stream has finished', () async {
    final source = File('${directory.path}/cached.png');
    await source.writeAsBytes([137, 80, 78, 71, 13, 10, 26, 10, 0, 0]);
    final item = _PageDownload(directory.path, {
      0: ['cached']
    });
    items.add(item);
    item.start();
    await until(() => item.requests.isNotEmpty);
    await item.complete('cached', cachedFile: source.path);
    await until(() => item.downloadedPages == 1);
    expect(await File('${directory.path}/0.png').readAsBytes(),
        await source.readAsBytes());
  });
}
