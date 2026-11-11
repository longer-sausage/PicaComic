import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/download_scheduler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void sample(AdaptiveDownloadConcurrency controller, int bytes,
      {int responseMs = 100, bool pending = true, int? active}) {
    controller.recordBytes(bytes);
    controller.recordResponse(Duration(milliseconds: responseMs));
    controller.recordSuccess();
    controller.sample(const Duration(seconds: 2),
        active: active ?? controller.limit, hasPending: pending);
  }

  test('probes more connections and retains only useful throughput gains', () {
    final controller = AdaptiveDownloadConcurrency();
    sample(controller, 2000000);
    expect(controller.limit, 8);
    sample(controller, 3000000);
    expect(controller.limit, 8);
    sample(controller, 3000000);
    expect(controller.limit, 10);
    sample(controller, 3000000);
    expect(controller.limit, 8);
    for (var i = 0; i < 3; i++) {
      sample(controller, 3000000);
      expect(controller.limit, 8, reason: 'Avoid probing on every sample');
    }
  });

  test('latency regression rejects a probe with only a small speed gain', () {
    final controller = AdaptiveDownloadConcurrency();
    sample(controller, 2000000, responseMs: 200);
    expect(controller.limit, 8);
    sample(controller, 2200000, responseMs: 1500);
    expect(controller.limit, 6);
  });

  test('congestion backs off once per window and stays within safe bounds', () {
    final controller = AdaptiveDownloadConcurrency();
    for (var i = 0; i < 40; i++) {
      controller.recordFailure(congested: true);
    }
    expect(controller.limit, 3);
    controller.sample(const Duration(seconds: 2), active: 6, hasPending: true);
    controller.recordFailure(congested: true);
    expect(controller.limit, 1);
    for (var i = 0; i < 80; i++) {
      sample(controller, 1000000 * (i + 1));
      expect(controller.limit, inInclusiveRange(1, 16));
    }
  });

  test('repeated failures and stalled first responses lower concurrency', () {
    final controller = AdaptiveDownloadConcurrency();
    controller.recordFailure();
    controller.recordFailure();
    controller.sample(const Duration(seconds: 2), active: 6, hasPending: true);
    expect(controller.limit, 3);
    for (var i = 0; i < 8; i++) {
      controller.sample(const Duration(seconds: 2),
          active: 3,
          hasPending: true,
          oldestResponse: const Duration(seconds: 10));
    }
    expect(controller.limit, 1);
  });

  test('tail pages and idle workers cannot trigger a concurrency probe', () {
    final controller = AdaptiveDownloadConcurrency();
    sample(controller, 2000000, pending: false);
    sample(controller, 2000000, active: 2);
    expect(controller.limit, 6);
  });

  testWidgets(
      'any completion immediately fills its slot despite a slow first task',
      (tester) async {
    final requests = <int>[];
    final pending = List.generate(5, (_) => Completer<void>());
    final scheduler = DownloadTaskScheduler<int>(
      tasks: [0, 1, 2, 3, 4],
      download: (page, _) {
        requests.add(page);
        return pending[page].future;
      },
      adaptive: () => false,
      fixedConcurrency: () => 2,
    );
    final done = scheduler.run();
    expect(requests, [0, 1]);
    pending[1].complete();
    await tester.pump();
    expect(requests, [0, 1, 2]);
    pending[2].complete();
    await tester.pump();
    expect(requests, [0, 1, 2, 3]);
    for (final page in [0, 3, 4]) {
      pending[page].complete();
      await tester.pump();
    }
    await done;
    expect(scheduler.activeCount, 0);
  });

  testWidgets('limits change live and lowering them lets existing work drain',
      (tester) async {
    var limit = 3;
    final requests = <int>[];
    final pending = List.generate(6, (_) => Completer<void>());
    final scheduler = DownloadTaskScheduler<int>(
      tasks: Iterable.generate(6),
      download: (page, _) {
        requests.add(page);
        return pending[page].future;
      },
      adaptive: () => false,
      fixedConcurrency: () => limit,
    );
    final done = scheduler.run();
    limit = 1;
    scheduler.refreshConcurrency();
    pending[1].complete();
    pending[2].complete();
    await tester.pump();
    expect(requests, [0, 1, 2]);
    limit = 2;
    scheduler.refreshConcurrency();
    expect(requests, [0, 1, 2, 3]);
    for (final page in [0, 3, 4, 5]) {
      pending[page].complete();
      await tester.pump();
    }
    await done;
  });

  testWidgets(
      'retrying one image does not occupy a slot or restart healthy work',
      (tester) async {
    final attempts = <int, int>{};
    final finished = <int>[];
    final scheduler = DownloadTaskScheduler<int>(
      tasks: [0, 1, 2],
      download: (page, _) async {
        attempts[page] = (attempts[page] ?? 0) + 1;
        if (page == 0 && attempts[page] == 1) {
          throw Exception('Temporary error');
        }
      },
      onComplete: finished.add,
      adaptive: () => false,
      fixedConcurrency: () => 1,
    );
    final done = scheduler.run();
    await tester.pump();
    expect(finished, [1, 2]);
    await tester.pump(const Duration(seconds: 2));
    await done;
    expect(attempts, {0: 2, 1: 1, 2: 1});
    expect(finished, [1, 2, 0]);
  });

  testWidgets('429 honors Retry-After and holds new work during the cooldown',
      (tester) async {
    final requests = <int>[];
    var first = true;
    final scheduler = DownloadTaskScheduler<int>(
      tasks: Iterable.generate(10),
      adaptive: () => true,
      fixedConcurrency: () => 6,
      download: (page, _) async {
        requests.add(page);
        if (page == 0 && first) {
          first = false;
          final options = RequestOptions(path: '/image');
          throw DioException.badResponse(
              statusCode: 429,
              requestOptions: options,
              response: Response(
                  requestOptions: options,
                  statusCode: 429,
                  headers: Headers.fromMap({
                    'retry-after': ['10']
                  })));
        }
      },
    );
    final done = scheduler.run();
    await tester.pump();
    expect(scheduler.concurrency, 3);
    final beforeCooldown = requests.length;
    await tester.pump(const Duration(seconds: 9));
    expect(requests.length, beforeCooldown);
    await tester.pump(const Duration(seconds: 2));
    await done;
    expect(requests.where((page) => page == 0).length, 2);
  });

  testWidgets('cancel aborts in-flight tokens and removes delayed retries',
      (tester) async {
    final contexts = <DownloadTaskContext>[];
    var requests = 0;
    final scheduler = DownloadTaskScheduler<int>(
      tasks: [0, 1, 2],
      adaptive: () => false,
      fixedConcurrency: () => 2,
      download: (page, task) async {
        requests++;
        contexts.add(task);
        if (page == 0) throw Exception('Retry later');
        await task.cancelToken.whenCancel;
      },
    );
    final done = scheduler.run();
    await tester.pump();
    scheduler.cancel();
    await done;
    await tester.pump(const Duration(seconds: 30));
    expect(contexts.skip(1).where((c) => !c.isCanceled), isEmpty);
    expect(requests, 3);
  });

  testWidgets('retry exhaustion fails once and aborts the other transfers',
      (tester) async {
    DownloadTaskContext? peer;
    final scheduler = DownloadTaskScheduler<int>(
      tasks: [0, 1],
      adaptive: () => false,
      fixedConcurrency: () => 2,
      maxRetries: 1,
      download: (page, task) async {
        if (page == 0) throw StateError('Failed');
        peer = task;
        await task.cancelToken.whenCancel;
      },
    );
    final done = expectLater(scheduler.run(), throwsStateError);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await done;
    expect(peer!.isCanceled, isTrue);
  });

  test('Retry-After accepts seconds and dates and ignores invalid values', () {
    expect(
        downloadRetryAfter(Headers.fromMap({
          'retry-after': ['7']
        })),
        const Duration(seconds: 7));
    expect(
        downloadRetryAfter(Headers.fromMap({
          'retry-after': ['Wed, 21 Oct 2015 07:28:00 GMT']
        })),
        Duration.zero);
    expect(
        downloadRetryAfter(Headers.fromMap({
          'retry-after': ['invalid']
        })),
        isNull);
  });
}
