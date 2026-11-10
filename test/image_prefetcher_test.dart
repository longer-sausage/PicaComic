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
}

class _TestProvider extends BaseImageProvider<_TestProvider> {
  _TestProvider(this.key);

  @override
  final String key;
  final result = Completer<Uint8List>();
  int loads = 0;

  @override
  Future<_TestProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents) {
    loads++;
    return result.future;
  }
}
