import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late CacheManager cache;

  setUpAll(() async {
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    }
    directory = await Directory.systemTemp.createTemp('pica-cache-test-');
    App.cachePath = directory.path;
    App.dataPath = directory.path;
    SingleInstanceCookieJar('${directory.path}/cookies.db');
  });

  setUp(() async {
    cache = CacheManager();
    cache.setLimitSize(100);
    await cache.clear();
  });

  tearDown(() async {
    await cache.clear();
    await cache.dispose();
  });

  tearDownAll(() async {
    ImageManager.cache?.dio.close(force: true);
    SingleInstanceCookieJar.instance?.dispose();
    SingleInstanceCookieJar.instance = null;
    expect(
        directory.absolute.path.startsWith(Directory.systemTemp.absolute.path),
        isTrue);
    expect(directory.uri.pathSegments.where((s) => s.isNotEmpty).last,
        startsWith('pica-cache-test-'));
    await directory.delete(recursive: true);
  });

  test('parallel buffered commits count every byte and close only once',
      () async {
    final data = Uint8List.fromList(List.generate(1200 * 1024, (i) => i % 251));
    await Future.wait(List.generate(16, (i) async {
      final writer = await cache.openWrite('page-$i');
      for (var offset = 0; offset < data.length; offset += 32 * 1024) {
        await writer.writeBytes(Uint8List.sublistView(
            data, offset, (offset + 32 * 1024).clamp(0, data.length)));
      }
      await Future.wait([writer.close(), writer.close()]);
      expect(
          await File((await cache.findCache('page-$i'))!).readAsBytes(), data);
    }));
    expect(cache.currentSize, data.length * 16);
    await cache.dispose();
    cache = CacheManager();
    await cache.checkCache();
    expect(cache.currentSize, data.length * 16);
    await Future.wait(List.generate(16, (i) => cache.delete('page-$i')));
    expect(cache.currentSize, 0);
  });

  test('replacing the same key removes old files and preserves size accounting',
      () async {
    await cache.writeCache('same', Uint8List(40));
    final original = File((await cache.findCache('same'))!);
    await Future.wait([
      cache.writeCache('same', Uint8List(70)),
      cache.writeCache('same', Uint8List(90)),
    ]);
    final current = File((await cache.findCache('same'))!);
    expect(await original.exists(), isFalse);
    expect(cache.currentSize, await current.length());
    expect(
        await Directory(CacheManager.cachePath)
            .list(recursive: true)
            .where((entry) => entry is File)
            .length,
        1);
    await cache.deleteKeyword('sam');
    expect(cache.currentSize, 0);
    expect(await cache.findCache('same'), isNull);
  });

  test('cancel removes its own committed bytes without deleting a replacement',
      () async {
    final old = await cache.openWrite('same');
    await old.writeBytes(Uint8List(100));
    await old.close();
    final replacement = await cache.openWrite('same');
    await replacement.writeBytes(Uint8List(200));
    await replacement.close();
    await old.cancel();
    expect(cache.currentSize, 200);
    expect(await cache.findCache('same'), replacement.file.path);
    await replacement.cancel();
    await replacement.cancel();
    expect(cache.currentSize, 0);
    expect(await cache.findCache('same'), isNull);
  });

  test('expiry cleanup and byte eviction leave accurate totals', () async {
    await cache.writeCache('old', Uint8List(100), -1);
    await cache.writeCache('keep', Uint8List(200));
    await cache.checkCache();
    expect(await cache.findCache('old'), isNull);
    expect(cache.currentSize, 200);
    cache.setLimitSize(1);
    for (var i = 0; i < 3; i++) {
      await cache.writeCache('large-$i', Uint8List(600 * 1024));
    }
    expect(cache.currentSize, lessThanOrEqualTo(1024 * 1024));
    expect(await cache.findCache('large-2'), isNotNull);
    final files = await Directory(CacheManager.cachePath)
        .list(recursive: true)
        .where((entry) => entry is File)
        .cast<File>()
        .toList();
    var actual = 0;
    for (final file in files) {
      actual += await file.length();
    }
    expect(cache.currentSize, actual);
  });

  test('entry cap evicts enough pages even when the byte limit is not reached',
      () async {
    await cache.dispose();
    final db = sqlite3.open('${directory.path}/cache.db');
    final seed = Directory('${CacheManager.cachePath}/seed')
      ..createSync(recursive: true);
    final expires =
        DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch;
    db.execute('BEGIN');
    for (var i = 0; i < 2000; i++) {
      File('${seed.path}/$i').writeAsBytesSync([i % 251]);
      db.execute('INSERT INTO cache VALUES (?, ?, ?, ?, NULL)',
          ['seed-$i', 'seed', '$i', expires + i]);
    }
    db.execute('COMMIT');
    db.dispose();
    cache = CacheManager();
    await Future.wait(
        List.generate(16, (i) => cache.writeCache('new-$i', Uint8List(2))));
    expect(cache.currentSize, 2000 - 16 + 32);
    for (var i = 0; i < 16; i++) {
      expect(await cache.findCache('seed-$i'), isNull);
      expect(await cache.findCache('new-$i'), isNotNull);
    }
    final check = sqlite3.open('${directory.path}/cache.db');
    expect(check.select('SELECT COUNT(*) FROM cache').first[0], 2000);
    check.dispose();
  });

  test(
      'maintenance terminates with orphan files and recovers from a failed commit',
      () async {
    final writer = await cache.openWrite('missing');
    await writer.file.delete();
    await expectLater(writer.close(), throwsA(isA<FileSystemException>()));
    await cache.writeCache('good', Uint8List(10));
    expect(cache.currentSize, 10);
    await cache.clear();
    await cache.dispose();
    File('${CacheManager.cachePath}/orphan')
        .writeAsBytesSync(Uint8List(2 * 1024 * 1024));
    cache = CacheManager()..setLimitSize(1);
    await cache.checkCache().timeout(const Duration(seconds: 3));
    await cache.clear();
    expect(cache.currentSize, 0);
  });

  test('JM recombination stores one image rather than appending a duplicate',
      () async {
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final image = Uint8List.fromList(
        [255, 216, 255, 224, ...List.generate(64, (i) => i)]);
    final gif = base64Decode(
        'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final isGif = request.uri.path.endsWith('.GIF');
      final data = isGif ? gif : image;
      request.response.headers.contentType =
          ContentType('image', isGif ? 'gif' : 'jpeg');
      request.response.contentLength = data.length;
      request.response.add(data);
      await request.response.close();
    });
    try {
      final progress = await ImageManager()
          .getJmImage('http://127.0.0.1:${server.port}/image.jpg', null,
              epsId: '1', scrambleId: '2', bookId: 'image')
          .toList();
      expect(progress.last.finished, isTrue);
      expect(progress.last.data, image);
      expect(await progress.last.getFile().readAsBytes(), image);
      expect(cache.currentSize, image.length);
      final animated = await ImageManager()
          .getJmImage(
              'http://127.0.0.1:${server.port}/image.GIF?token=test', null,
              epsId: '300000', scrambleId: '1', bookId: 'image')
          .toList();
      expect(animated.last.data, gif);
      expect(await animated.last.getFile().readAsBytes(), gif);
      expect(cache.currentSize, image.length + gif.length);
    } finally {
      await server.close(force: true);
      HttpOverrides.global = overrides;
    }
  });
}
