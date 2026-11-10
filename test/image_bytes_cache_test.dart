import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/image_loader/image_bytes_cache.dart';

void main() {
  test('shares concurrent loads and retries a failed request', () async {
    final cache = ImageBytesCache(maximumSizeBytes: 16);
    final result = Completer<Uint8List>();
    var calls = 0;
    Future<Uint8List> load() {
      calls++;
      return result.future;
    }

    final first = cache.load('image', load);
    final second = cache.load('image', load);
    expect(identical(first, second), isTrue);
    final failure = expectLater(first, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    result.completeError(StateError('network failure'));
    await failure;
    final bytes = Uint8List(8);
    expect(await cache.load('image', () async => bytes), same(bytes));
    expect(cache.sizeBytes, 8);
  });

  test('enforces its byte limit and evicts the least recently read entry',
      () async {
    final cache = ImageBytesCache(maximumSizeBytes: 10);
    Future<Uint8List> bytes() async => Uint8List(4);
    await cache.load('a', bytes);
    await cache.load('b', bytes);
    await cache.load('a', bytes);
    await cache.load('c', bytes);
    expect(cache.containsKey('a'), isTrue);
    expect(cache.containsKey('b'), isFalse);
    expect(cache.containsKey('c'), isTrue);
    expect(cache.sizeBytes, 8);

    await cache.load('oversize', () async => Uint8List(20));
    expect(cache.containsKey('oversize'), isFalse);
    expect(cache.sizeBytes, 8);
    cache.maximumSizeBytes = 3;
    expect(cache.sizeBytes, 0);
  });

  test('clearing ignores old loads without removing a newer pending request',
      () async {
    final cache = ImageBytesCache(maximumSizeBytes: 10);
    final old = Completer<Uint8List>();
    final next = Completer<Uint8List>();
    final beforeClear = cache.load('image', () => old.future);
    cache.clear();
    final afterClear = cache.load('image', () => next.future);
    old.complete(Uint8List(4));
    await beforeClear;
    expect(cache.sizeBytes, 0);
    expect(cache.load('image', () async => fail('duplicate load')),
        same(afterClear));
    next.complete(Uint8List(6));
    await afterClear;
    expect(cache.sizeBytes, 6);
  });
}
