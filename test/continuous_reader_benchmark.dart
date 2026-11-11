// Run explicitly: flutter test --no-pub test/continuous_reader_benchmark.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';
import 'package:pica_comic/foundation/image_loader/image_prefetcher.dart';
import 'package:pica_comic/foundation/image_loader/stream_image_provider.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:sqlite3/open.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('compare protected and pipelined continuous downloads over loopback',
      () async {
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    }
    final directory =
        await Directory.systemTemp.createTemp('pica-continuous-bench-');
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final cookies = SingleInstanceCookieJar('${directory.path}/cookies.db');
    final cache = CacheManager();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bytes = File('test/fixtures/animated.webp').readAsBytesSync();
    server.listen((request) async {
      final page = int.parse(request.uri.pathSegments.last);
      await Future<void>.delayed(Duration(milliseconds: page == 0 ? 400 : 50));
      request.response.headers.contentType = ContentType('image', 'webp');
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });

    try {
      Future<Map<String, Object>> measure(String label, bool pipelined) async {
        BaseImageProvider.clearCache();
        await cache.clear();
        final clock = Stopwatch()..start();
        final finished = List.generate(7, (_) => Completer<void>());
        final startedAt = List.filled(7, -1);
        final finishedAt = List.filled(7, -1);
        var active = 0;
        var peak = 0;
        final images = List.generate(7, (page) {
          final url = 'http://127.0.0.1:${server.port}/$label/$page';
          return StreamImageProvider(() async* {
            startedAt[page] = clock.elapsedMilliseconds;
            active++;
            if (active > peak) peak = active;
            try {
              yield* ImageManager().getImage(url);
              finishedAt[page] = clock.elapsedMilliseconds;
              finished[page].complete();
            } catch (error, stack) {
              finished[page].completeError(error, stack);
              rethrow;
            } finally {
              active--;
            }
          }, url);
        });
        final prefetcher = ImagePrefetcher();
        prefetcher.prefetch(images.skip(1),
            priority: [images.first],
            concurrency: pipelined ? 6 : 2,
            waitForPriority: !pipelined);
        try {
          await Future.wait(finished.map((item) => item.future))
              .timeout(const Duration(seconds: 10));
          await Future<void>.delayed(Duration.zero);
          expect(images.every((image) => image.isByteCached), isTrue);
          expect(peak, lessThanOrEqualTo(pipelined ? 6 : 2));
          expect(
              startedAt[1],
              pipelined
                  ? lessThan(finishedAt[0])
                  : greaterThanOrEqualTo(finishedAt[0]));
          return {
            'first_page_ready_ms': finishedAt.first,
            'following_six_ready_ms':
                finishedAt.skip(1).reduce((a, b) => a > b ? a : b),
            'peak_requests': peak,
            'request_started_ms': startedAt,
            'request_finished_ms': finishedAt,
          };
        } finally {
          prefetcher.dispose();
        }
      }

      // Initialize the adapter and cache before comparing both policies.
      await ImageManager()
          .getImage('http://127.0.0.1:${server.port}/warmup/7')
          .drain<void>();
      final protectedRuns = <Map<String, Object>>[];
      final pipelinedRuns = <Map<String, Object>>[];
      for (var run = 0; run < 3; run++) {
        if (run.isEven) {
          protectedRuns.add(await measure('protected-$run', false));
          pipelinedRuns.add(await measure('pipelined-$run', true));
        } else {
          pipelinedRuns.add(await measure('pipelined-$run', true));
          protectedRuns.add(await measure('protected-$run', false));
        }
      }
      Map<String, Object> summarize(List<Map<String, Object>> runs) {
        final timings = runs
            .map((run) => run['following_six_ready_ms'] as int)
            .toList()
          ..sort();
        return {
          'median_following_six_ready_ms': timings[1],
          'runs': runs,
        };
      }

      final report = {
        'scenario': '7 WebP HTTP requests; page 0 delayed 400 ms, others 50 ms; '
            'real local transport and disk cache; encoded bytes only; '
            '3 runs per policy with alternating order after connection warmup',
        'protected': summarize(protectedRuns),
        'pipelined': summarize(pipelinedRuns),
      };
      await File('build/continuous-reader-benchmark.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      // ignore: avoid_print
      print(const JsonEncoder.withIndent('  ').convert(report));
    } finally {
      await server.close(force: true);
      ImageManager.cache?.dio.close(force: true);
      await cache.dispose();
      cookies.dispose();
      SingleInstanceCookieJar.instance = null;
      BaseImageProvider.clearCache();
      PaintingBinding.instance.imageCache.clear();
      HttpOverrides.global = overrides;
      expect(
          directory.absolute.path
              .startsWith(Directory.systemTemp.absolute.path),
          isTrue);
      expect(directory.uri.pathSegments.where((s) => s.isNotEmpty).last,
          startsWith('pica-continuous-bench-'));
      await directory.delete(recursive: true);
    }
  });
}
