import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/network/picacg_network/models.dart';
import 'package:pica_comic/network/picacg_network/picacg_download_model.dart';
import 'package:pica_comic/tools/download_runtime.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:sqlite3/open.dart';

class _ControlledDownload extends PicDownloadingItem {
  int starts = 0;
  int pauses = 0;
  int stops = 0;
  final completed = Completer<void>();

  _ControlledDownload(PicDownloadingItem item)
      : super(item.comic, [0], item.onFinish, item.onError, item.updateInfo,
            item.id) {
    directory = item.id;
  }

  @override
  void start() => starts++;

  @override
  void pause() => pauses++;

  @override
  void stop() => stops++;

  @override
  Future<DownloadedItem> toDownloadedItem() async {
    await completed.future;
    return DownloadedComic(comic, ['Chapter 1'], 0, [0]);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late DownloadManager manager;
  late Directory directory;
  final calls = <String>[];
  Completer<void>? nativeStart;

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  // Keep the production queue callbacks but replace network transfers with a
  // controllable task so races can be exercised without a remote comic server.
  _ControlledDownload enqueue(String id) {
    final wasDownloading = manager.isDownloading;
    manager.isDownloading = true;
    manager.addPicDownload(
        ComicItem(
            Profile('creator', '', '', 0, 0, '', '', false, null, null),
            'Comic $id',
            '',
            '',
            '',
            '',
            [],
            [],
            0,
            0,
            false,
            false,
            1,
            id,
            1,
            '',
            ['Chapter 1'],
            []),
        [0]);
    final item = _ControlledDownload(
        manager.downloading.removeLast() as PicDownloadingItem);
    manager.downloading.add(item);
    manager.isDownloading = wasDownloading;
    return item;
  }

  setUpAll(() {
    AppTranslation.translations = {};
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    }
  });

  setUp(() async {
    calls.clear();
    nativeStart = null;
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(DownloadRuntime.channel, (call) async {
      calls.add(call.method);
      if (call.method == 'start') await nativeStart?.future;
      return null;
    });
    directory = await Directory.systemTemp.createTemp('pica-download-tests-');
    appdata.settings[22] = directory.path;
    DownloadManager.cache = null;
    manager = DownloadManager();
    await manager.init();
  });

  tearDown(() async {
    nativeStart?.complete();
    nativeStart = null;
    manager.dispose();
    await settle();
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(DownloadRuntime.channel, null);
    DownloadRuntime.channel.setMethodCallHandler(null);
    expect(
        directory.absolute.path.startsWith(Directory.systemTemp.absolute.path),
        isTrue);
    expect(directory.uri.pathSegments.where((s) => s.isNotEmpty).last,
        startsWith('pica-download-tests-'));
    await directory.delete(recursive: true);
  });

  test('download waits for native protection and pause cancels a pending start',
      () async {
    final item = enqueue('first');
    nativeStart = Completer<void>();
    final starting = manager.start();
    await settle();
    expect(item.starts, 0);
    manager.pause();
    nativeStart!.complete();
    nativeStart = null;
    await starting;
    await settle();
    expect(item.starts, 0);
    expect(item.pauses, 1);
    expect(calls, ['start', 'stop']);
    expect(manager.isDownloading, isFalse);
  });

  test('resume after a pending start runs the task once with protection active',
      () async {
    final item = enqueue('first');
    nativeStart = Completer<void>();
    final oldStart = manager.start();
    manager.pause();
    final newStart = manager.start();
    nativeStart!.complete();
    nativeStart = null;
    await Future.wait([oldStart, newStart]);
    expect(item.starts, 1);
    expect(calls, ['start', 'stop', 'start']);
    expect(manager.isDownloading, isTrue);
  });

  test('canceling a queued task leaves the active task running once', () async {
    final first = enqueue('first');
    final second = enqueue('second');
    await manager.start();
    manager.cancel(second.id);
    await settle();
    expect(first.starts, 1);
    expect(first.stops, 0);
    expect(calls, ['start']);
  });

  test('canceling a paused task does not resume the next task', () async {
    final first = enqueue('first');
    final second = enqueue('second');
    manager.cancel(first.id);
    await settle();
    expect(first.stops, 1);
    expect(second.starts, 0);
    expect(manager.isDownloading, isFalse);
    expect(calls, isEmpty);
  });

  test('canceling the active task protects its successor and releases on empty',
      () async {
    final first = enqueue('first');
    final second = enqueue('second');
    await manager.start();
    manager.cancel(first.id);
    await settle();
    expect(first.stops, 1);
    expect(second.starts, 1);
    expect(manager.isDownloading, isTrue);
    manager.cancel(second.id);
    await settle();
    expect(manager.isDownloading, isFalse);
    expect(calls.last, 'stop');
  });

  test('completion releases protection after committing the last task',
      () async {
    final item = enqueue('first');
    await manager.start();
    item.onFinish!();
    await settle();
    expect(calls, ['start']);
    item.completed.complete();
    await settle();
    expect(manager.isExists(item.id), isTrue);
    expect(manager.downloading, isEmpty);
    expect(manager.isDownloading, isFalse);
    expect(calls, ['start', 'stop']);
  });

  test('pausing during task finalization does not start the next task',
      () async {
    final first = enqueue('first');
    final second = enqueue('second');
    await manager.start();
    first.onFinish!();
    manager.pause();
    first.completed.complete();
    await settle();
    expect(second.starts, 0);
    expect(manager.isDownloading, isFalse);
    expect(calls, ['start', 'stop']);
  });

  test('canceling the next task during finalization starts its successor once',
      () async {
    final first = enqueue('first');
    final second = enqueue('second');
    final third = enqueue('third');
    await manager.start();
    first.onFinish!();
    manager.cancel(second.id);
    await settle();
    expect(third.starts, 1);
    first.completed.complete();
    await settle();
    expect(third.starts, 1);
    expect(manager.isDownloading, isTrue);
  });

  test('concurrent progress saves leave a complete, current queue snapshot',
      () async {
    final item = enqueue('first');
    final saves = <Future<void>>[];
    for (var i = 0; i < 50; i++) {
      item.index = i;
      saves.add(item.updateInfo!());
    }
    await Future.wait(saves);
    final saved = jsonDecode(
        await File('${directory.path}/newDownload.json').readAsString());
    expect(saved['downloading'].single['index'], 49);
  });

  test('OS expiration persists the queue and resumes only after foregrounding',
      () async {
    final item = enqueue('first');
    await manager.start();
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      DownloadRuntime.channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('expired')),
      (_) {},
    );
    expect(manager.isDownloading, isFalse);
    expect(item.pauses, 1);
    final saved = jsonDecode(
        await File('${directory.path}/newDownload.json').readAsString());
    expect(saved['downloading'].single['id'], item.id);
    manager.didChangeAppLifecycleState(AppLifecycleState.paused);
    await settle();
    expect(item.starts, 1);
    manager.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settle();
    expect(item.starts, 2);
    expect(manager.isDownloading, isTrue);
  });

  test('manual pause after expiration cancels automatic resume', () async {
    final item = enqueue('first');
    await manager.start();
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      DownloadRuntime.channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('expired')),
      (_) {},
    );
    manager.pause();
    manager.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settle();
    expect(item.starts, 1);
    expect(manager.isDownloading, isFalse);
  });

  test('an empty queue can be started and paused safely', () async {
    await manager.start();
    manager.pause();
    await settle();
    expect(manager.isDownloading, isFalse);
    expect(calls, ['stop']);
  });
}
