import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'animated_image_codec.dart';

/// Shares decoded frames at a stable physical display size.
class OptimizedImageProvider extends ImageProvider<OptimizedImageKey> {
  const OptimizedImageProvider(
    this.provider, {
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.resizeStatic = true,
  });

  final ImageProvider provider;
  final int? width;
  final int? height;
  final BoxFit fit;
  final bool resizeStatic;

  @override
  bool operator ==(Object other) =>
      other is OptimizedImageProvider &&
      provider == other.provider &&
      width == other.width &&
      height == other.height &&
      fit == other.fit &&
      resizeStatic == other.resizeStatic;

  @override
  int get hashCode => Object.hash(provider, width, height, fit, resizeStatic);

  @override
  Future<OptimizedImageKey> obtainKey(ImageConfiguration configuration) {
    return provider.obtainKey(configuration).then(
          (key) => OptimizedImageKey(key, width, height, fit, resizeStatic),
        );
  }

  @override
  ImageStreamCompleter loadImage(
      OptimizedImageKey key, ImageDecoderCallback decode) {
    bool isLive() => PaintingBinding.instance.imageCache.statusForKey(key).live;
    AnimatedImageCodec? animation;
    late final ImageStreamCompleter completer;
    completer = provider.loadImage(key.providerKey, (
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) async {
      int? targetWidth;
      int? targetHeight;
      final codec = await decode(buffer, getTargetSize: (width, height) {
        if (getTargetSize != null) {
          final target = getTargetSize(width, height);
          targetWidth = target.width ??
              (target.height == null
                  ? width
                  : (target.height! * width / height).round());
          targetHeight = target.height ??
              (target.width == null
                  ? height
                  : (target.width! * height / width).round());
          return target;
        }
        final widthScale = key.width == null ? null : key.width! / width;
        final heightScale = key.height == null ? null : key.height! / height;
        final double scale;
        if (widthScale == null) {
          scale = heightScale ?? 1;
        } else if (heightScale == null) {
          scale = widthScale;
        } else if (key.fit == BoxFit.cover) {
          scale = math.max(widthScale, heightScale);
        } else if (key.fit == BoxFit.fitWidth) {
          scale = widthScale;
        } else if (key.fit == BoxFit.fitHeight) {
          scale = heightScale;
        } else {
          scale = math.min(widthScale, heightScale);
        }
        final clampedScale = math.min(1.0, scale);
        targetWidth = math.max(1, (width * clampedScale).ceil());
        targetHeight = math.max(1, (height * clampedScale).ceil());
        // Reading still images retains the full detail needed for pinch zoom.
        return key.resizeStatic
            ? ui.TargetImageSize(width: targetWidth, height: targetHeight)
            : const ui.TargetImageSize();
      });
      if (codec.frameCount == 1) return codec;
      return animation = AnimatedImageCodec(codec,
          targetWidth: targetWidth,
          targetHeight: targetHeight,
          isActive: isLive, onResume: () {
        final decodeHandle = completer.keepAlive();
        // Flutter removes this callback after each invocation.
        completer.addOnLastListenerRemovedCallback(() {
          animation?.pause();
          scheduleMicrotask(() async {
            // The image cache only accounts for the small displayed frame,
            // not the native codec's full-sized composition buffers. Release
            // inactive codecs, after any in-flight decode has finished.
            try {
              await animation?.whenIdle;
              if (!isLive()) {
                PaintingBinding.instance.imageCache
                    .evict(key, includeLive: false);
              }
            } finally {
              decodeHandle.dispose();
            }
          });
        });
      });
    });
    completer.addEphemeralErrorListener((error, stack) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    });
    return completer;
  }
}

@immutable
class OptimizedImageKey {
  const OptimizedImageKey(
      this.providerKey, this.width, this.height, this.fit, this.resizeStatic);

  final Object providerKey;
  final int? width;
  final int? height;
  final BoxFit fit;
  final bool resizeStatic;

  @override
  bool operator ==(Object other) =>
      other is OptimizedImageKey &&
      other.providerKey == providerKey &&
      other.width == width &&
      other.height == height &&
      other.fit == fit &&
      other.resizeStatic == resizeStatic;

  @override
  int get hashCode =>
      Object.hash(providerKey, width, height, fit, resizeStatic);
}
