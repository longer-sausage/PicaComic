import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Reuses GPU images after the first animation loop, within a shared budget.
/// Large animations keep streaming rather than filling memory with all frames.
class AnimatedImageCodec implements ui.Codec {
  AnimatedImageCodec(this._codec,
      {this.targetWidth, this.targetHeight, this.onResume, this.isActive})
      : frameCount = _codec.frameCount,
        repetitionCount = _codec.repetitionCount;

  final ui.Codec _codec;
  final int? targetWidth;
  final int? targetHeight;
  final VoidCallback? onResume;
  final bool Function()? isActive;
  @override
  final int frameCount;
  @override
  final int repetitionCount;

  final _frames = <_CachedFrame>[];
  Future<void>? _pending;
  bool _disposed = false;
  bool _canCache = true;
  bool _active = false;
  int _reservedBytes = 0;
  int _nextCachedFrame = 0;
  int _cacheGeneration = 0;

  @visibleForTesting
  static int get cachedBytes => _AnimationCacheBudget.instance.usedBytes;

  static void clearCache() => _AnimationCacheBudget.instance.clear();

  Future<void> get whenIdle => _pending ?? Future<void>.value();

  @override
  Future<ui.FrameInfo> getNextFrame() {
    final result = _getNextFrame(_pending);
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<ui.FrameInfo> _getNextFrame(Future<void>? previous) async {
    await previous;
    if (_disposed) throw StateError('Image codec is disposed');
    // MultiFrameImageStreamCompleter can request one more frame while its
    // first-frame cache listener is removing itself. Do not reactivate then.
    if (!_active && (isActive?.call() ?? true)) {
      _active = true;
      _canCache = true;
      onResume?.call();
    }
    if (_frames.length == frameCount) {
      final frame = _frames[_nextCachedFrame];
      _nextCachedFrame = (_nextCachedFrame + 1) % frameCount;
      return _CachedFrame(frame.image.clone(), frame.duration);
    }

    final generation = _cacheGeneration;
    final frame = await _codec.getNextFrame();
    if (_disposed) {
      frame.image.dispose();
      throw StateError('Image codec is disposed');
    }
    if (generation != _cacheGeneration ||
        !_active ||
        !_canCache ||
        frameCount < 2 ||
        repetitionCount == 0) {
      return frame;
    }

    // Some Flutter engines ignore target size for multi-frame images. Resize
    // the completed frame once, then reuse that texture on subsequent loops.
    final width = math.min(targetWidth ?? frame.image.width, frame.image.width);
    final height =
        math.min(targetHeight ?? frame.image.height, frame.image.height);
    if (_reservedBytes == 0) {
      final bytes = width * height * 4 * frameCount;
      if (!_AnimationCacheBudget.instance.reserve(this, bytes)) {
        _canCache = false;
        return frame;
      }
      _reservedBytes = bytes;
    }

    ui.Image image = frame.image;
    if (width != image.width || height != image.height) {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.low,
      );
      final picture = recorder.endRecording();
      try {
        image = await picture.toImage(width, height);
      } catch (_) {
        _releaseFrames();
        if (_disposed) {
          frame.image.dispose();
          throw StateError('Image codec is disposed');
        }
        return frame;
      } finally {
        picture.dispose();
      }
      frame.image.dispose();
    }
    if (_disposed) {
      image.dispose();
      throw StateError('Image codec is disposed');
    }
    // A memory-pressure callback may have released the reservation while the
    // raster thread was producing the resized image.
    if (_canCache && generation == _cacheGeneration) {
      _frames.add(_CachedFrame(image.clone(), frame.duration));
    }
    return _CachedFrame(image, frame.duration);
  }

  void _releaseFrames() {
    _cacheGeneration++;
    _canCache = false;
    for (final frame in _frames) {
      frame.image.dispose();
    }
    _frames.clear();
    _AnimationCacheBudget.instance.release(this, _reservedBytes);
    _reservedBytes = 0;
    _nextCachedFrame = 0;
  }

  /// Offscreen images must not occupy the budget needed by visible animations.
  void pause() {
    _active = false;
    _releaseFrames();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _releaseFrames();
    _codec.dispose();
  }
}

class _CachedFrame implements ui.FrameInfo {
  const _CachedFrame(this.image, this.duration);

  @override
  final ui.Image image;
  @override
  final Duration duration;
}

class _AnimationCacheBudget with WidgetsBindingObserver {
  _AnimationCacheBudget() {
    WidgetsBinding.instance.addObserver(this);
  }

  static final instance = _AnimationCacheBudget();
  static const maximumBytes = 64 * 1024 * 1024;
  static const maximumBytesPerImage = 24 * 1024 * 1024;
  final _owners = <AnimatedImageCodec>{};
  int usedBytes = 0;

  bool reserve(AnimatedImageCodec codec, int bytes) {
    if (bytes > maximumBytesPerImage || usedBytes + bytes > maximumBytes) {
      return false;
    }
    usedBytes += bytes;
    _owners.add(codec);
    return true;
  }

  void release(AnimatedImageCodec codec, int bytes) {
    usedBytes -= bytes;
    _owners.remove(codec);
  }

  void clear() {
    for (final codec in _owners.toList()) {
      codec._releaseFrames();
    }
  }

  @override
  void didHaveMemoryPressure() => clear();
}
