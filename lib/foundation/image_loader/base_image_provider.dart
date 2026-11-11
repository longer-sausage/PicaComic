import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/image_manager.dart';

import 'image_bytes_cache.dart';

abstract class BaseImageProvider<T extends BaseImageProvider<T>>
    extends ImageProvider<T> {
  const BaseImageProvider();

  static final _cache = ImageBytesCache(maximumSizeBytes: 50 * 1024 * 1024);
  static final _progress = <String, _ImageLoadProgress>{};

  bool get isByteCached => _cache.containsKey(key);

  /// Loading and prefetching share one request, including resized variants.
  Future<Uint8List> loadBytes({void Function(ImageChunkEvent)? onChunk}) async {
    final progress = _progress.putIfAbsent(key, _ImageLoadProgress.new);
    final listener = onChunk == null ? null : progress.listen(onChunk);
    try {
      return await _cache.load(key, () async {
        final events = StreamController<ImageChunkEvent>(sync: true);
        final progressClock = Stopwatch()..start();
        var lastProgress = -50;
        final subscription = events.stream.listen((event) {
          progress.latest = event;
          final now = progressClock.elapsedMilliseconds;
          if (now - lastProgress >= 50 ||
              event.cumulativeBytesLoaded == event.expectedTotalBytes) {
            lastProgress = now;
            progress.notify(event);
          }
        });
        try {
          var retries = 0;
          while (true) {
            try {
              final data = await load(events);
              if (data.isEmpty) throw StateError('Empty image data');
              return data;
            } catch (e) {
              if (e is StateError ||
                  e is BadRequestException ||
                  e
                      .toString()
                      .contains('Maximum image loading limit reached') ||
                  e.toString().contains('Your IP address')) {
                rethrow;
              }
              if (e.toString().contains('handshake') || retries == 3) rethrow;
              // Recover brief transport failures without leaving a page waiting
              // through the previous 2 + 4 + 8 second retry delays.
              await Future<void>.delayed(
                  Duration(milliseconds: const [250, 750, 1500][retries++]));
            }
          }
        } finally {
          await events.close();
          await subscription.cancel();
        }
      });
    } finally {
      if (listener != null) progress.listeners.remove(listener);
      if (identical(_progress[key], progress)) _progress.remove(key);
    }
  }

  @override
  ImageStreamCompleter loadImage(T key, ImageDecoderCallback decode) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    var cancelled = false;
    chunkEvents.onCancel = () => cancelled = true;
    return MultiFrameImageStreamCompleter(
      codec: _loadBufferAsync(key, decode, (event) {
        if (!cancelled) chunkEvents.add(event);
      }).whenComplete(chunkEvents.close),
      chunkEvents: chunkEvents.stream,
      scale: 1.0,
      debugLabel: key.toString(),
      informationCollector: () sync* {
        yield DiagnosticsProperty<ImageProvider>('Image provider', this);
      },
    );
  }

  Future<ui.Codec> _loadBufferAsync(
    T key,
    ImageDecoderCallback decode,
    void Function(ImageChunkEvent) onChunk,
  ) async {
    try {
      for (var attempt = 0;; attempt++) {
        final data = await loadBytes(onChunk: onChunk);
        try {
          return await decode(await ui.ImmutableBuffer.fromUint8List(data));
        } catch (e) {
          // Do not repeatedly decode corrupt bytes from the memory cache.
          _cache.evict(this.key);
          await CacheManager().delete(this.key);
          // A truncated disk entry or a transient non-image response should not
          // leave a hole in the reader. Refetch once before showing a retry.
          if (attempt == 0) continue;
          Object error = e;
          if (data.length < 2 * 1024) {
            try {
              final text = const Utf8Codec().decoder.convert(data);
              error = Exception('Expected image data, but got text: $text');
            } catch (_) {
              // Binary data cannot be included in a useful text error.
            }
          }
          throw error;
        }
      }
    } catch (_) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    }
  }

  static void clearCache() {
    _cache.clear();
    _progress.clear();
  }

  static void setCacheSizeLimit(int size) => _cache.maximumSizeBytes = size;

  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents);

  String get key;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is BaseImageProvider<T> &&
      key == other.key;

  @override
  int get hashCode => Object.hash(runtimeType, key);

  @override
  String toString() => '$runtimeType($key)';
}

class _ImageLoadProgress {
  ImageChunkEvent? latest;
  final listeners = <Object, void Function(ImageChunkEvent)>{};

  Object listen(void Function(ImageChunkEvent) callback) {
    final token = Object();
    listeners[token] = callback;
    if (latest != null) callback(latest!);
    return token;
  }

  void notify(ImageChunkEvent event) {
    for (final callback in listeners.values.toList()) {
      callback(event);
    }
  }
}

typedef FileDecoderCallback = Future<ui.Codec> Function(Uint8List);
