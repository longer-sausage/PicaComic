import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/image_loader/base_image_provider.dart';
import 'package:pica_comic/foundation/image_loader/image_prefetcher.dart';
import 'package:pica_comic/foundation/image_loader/stream_image_provider.dart';

void main() {
  tearDown(BaseImageProvider.clearCache);

  test('limits concurrent loads and replaces stale queued pages', () async {
    final prefetcher = ImagePrefetcher();
    final images = List.generate(5, (index) => _TestProvider('$index'));
    prefetcher.prefetch(images.take(4));
    await Future<void>.delayed(Duration.zero);
    expect(images.map((image) => image.loads), [1, 1, 0, 0, 0]);
    prefetcher.prefetch([images[4]]);
    images[0].result.complete(Uint8List(1));
    await Future<void>.delayed(Duration.zero);
    expect(images.map((image) => image.loads), [1, 1, 0, 0, 1]);
    prefetcher.dispose();
    images[1].result.complete(Uint8List(1));
    images[4].result.complete(Uint8List(1));
    await Future<void>.delayed(Duration.zero);
  });

  test('prefetch and display share encoded data without invoking a decoder',
      () async {
    final prefetcher = ImagePrefetcher();
    final image = _TestProvider('shared');
    prefetcher.prefetch([image, image]);
    final display = image.loadBytes();
    await Future<void>.delayed(Duration.zero);
    expect(image.loads, 1);
    image.result.complete(Uint8List(8));
    expect((await display).length, 8);
    prefetcher.prefetch([image]);
    await Future<void>.delayed(Duration.zero);
    expect(image.loads, 1);
    expect(image.isByteCached, isTrue);
    final otherProvider = StreamImageProvider(
      () => throw StateError(
          'Encoded data should be shared across provider types'),
      'shared',
    );
    expect((await otherProvider.loadBytes()).length, 8);
    prefetcher.dispose();
  });

  test('a visible page starts before lookahead and bypasses stale requests',
      () async {
    final prefetcher = ImagePrefetcher();
    final images = List.generate(6, (index) => _TestProvider('$index'));
    prefetcher.prefetch(images.skip(1).take(2), priority: [images.first]);
    await Future<void>.delayed(Duration.zero);
    expect(images.map((image) => image.loads), [1, 0, 0, 0, 0, 0]);
    images.first.result.complete(Uint8List(1));
    await Future<void>.delayed(Duration.zero);
    expect(images.map((image) => image.loads), [1, 1, 1, 0, 0, 0]);
    prefetcher.prefetch([images[5]], priority: [images[4]]);
    await Future<void>.delayed(Duration.zero);
    expect(images[4].loads, 1,
        reason: 'Do not wait for the two stale downloads');
    images[1].result.complete(Uint8List(1));
    images[2].result.complete(Uint8List(1));
    await Future<void>.delayed(Duration.zero);
    expect(images[5].loads, 0,
        reason: 'Reserve bandwidth for the visible page');
    images[4].result.complete(Uint8List(1));
    await Future<void>.delayed(Duration.zero);
    expect(images[5].loads, 1);
    prefetcher.dispose();
    images[5].result.complete(Uint8List(1));
    await Future<void>.delayed(Duration.zero);
  });

  test('joining a prefetch replays progress and broadcasts completion',
      () async {
    final image = _TestProvider('progress');
    final prefetch = image.loadBytes();
    await Future<void>.delayed(Duration.zero);
    image.events!.add(const ImageChunkEvent(
        cumulativeBytesLoaded: 25, expectedTotalBytes: 100));
    final first = <ImageChunkEvent>[];
    final second = <ImageChunkEvent>[];
    final displays = [
      image.loadBytes(onChunk: first.add),
      image.loadBytes(onChunk: second.add),
    ];
    expect(first.single.cumulativeBytesLoaded, 25);
    expect(second.single.cumulativeBytesLoaded, 25);
    image.events!.add(const ImageChunkEvent(
        cumulativeBytesLoaded: 100, expectedTotalBytes: 100));
    expect(first.last.cumulativeBytesLoaded, 100);
    expect(second.last.cumulativeBytesLoaded, 100);
    image.result.complete(Uint8List(100));
    await Future.wait([prefetch, ...displays]);
    expect(image.loads, 1);
  });

  test('continuous lookahead fills and replenishes slots behind a slow page',
      () async {
    final prefetcher = ImagePrefetcher();
    final images = List.generate(10, (index) => _TestProvider('$index'));
    prefetcher.prefetch(images.skip(1),
        priority: [images.first], concurrency: 6, waitForPriority: false);
    await Future<void>.delayed(Duration.zero);
    expect(images.map((image) => image.loads), [1, 1, 1, 1, 1, 1, 0, 0, 0, 0]);
    for (final image in images.skip(1).take(5)) {
      image.result.complete(Uint8List(1));
    }
    await Future<void>.delayed(Duration.zero);
    expect(images.every((image) => image.loads == 1), isTrue);
    expect(images.first.result.isCompleted, isFalse,
        reason: 'A slow first page must not block all following pages');
    prefetcher.dispose();
    for (final image in images) {
      if (!image.result.isCompleted) image.result.complete(Uint8List(1));
    }
    await Future<void>.delayed(Duration.zero);
  });

  test('repeated jumps bound active prefetches and replace pending priorities',
      () async {
    final prefetcher = ImagePrefetcher();
    final images = List.generate(8, (index) => _TestProvider('$index'));
    prefetcher.prefetch(images.take(2));
    prefetcher.prefetch([], priority: images.skip(2).take(2));
    prefetcher.prefetch([], priority: [images[4]]);
    prefetcher.prefetch([], priority: [images[5]]);
    await Future<void>.delayed(Duration.zero);
    expect(images.map((image) => image.loads), [1, 1, 1, 1, 0, 0, 0, 0]);
    images.first.result.complete(Uint8List(1));
    await Future<void>.delayed(Duration.zero);
    expect(images[4].loads, 0);
    expect(images[5].loads, 1);
    prefetcher.dispose();
    for (final image in images.skip(1)) {
      image.result.complete(Uint8List(1));
    }
    await Future<void>.delayed(Duration.zero);
  });

  testWidgets('a transient reader request retries after 250 ms',
      (tester) async {
    final image = _TransientProvider();
    var complete = false;
    final request = image.loadBytes().then((_) => complete = true);
    await tester.pump();
    expect(image.loads, 1);
    await tester.pump(const Duration(milliseconds: 249));
    expect(image.loads, 1);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(image.loads, 2);
    expect(complete, isTrue);
    await request;
  });
}

class _TransientProvider extends BaseImageProvider<_TransientProvider> {
  int loads = 0;

  @override
  String get key => 'transient';
  @override
  Future<_TransientProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) async {
    if (++loads == 1) throw Exception('connection reset');
    return Uint8List(1);
  }
}

class _TestProvider extends BaseImageProvider<_TestProvider> {
  _TestProvider(this.key);

  @override
  final String key;
  final result = Completer<Uint8List>();
  int loads = 0;
  StreamController<ImageChunkEvent>? events;

  @override
  Future<_TestProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) {
    loads++;
    events = chunkEvents;
    return result.future;
  }
}
