import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/image_loader/animated_image_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(AnimatedImageCodec.clearCache);

  test(
      'a pause during decoding cannot insert frames into a new cache generation',
      () async {
    final data = await File('test/fixtures/animated.webp').readAsBytes();
    final native = _GatedCodec(await ui.instantiateImageCodec(data));
    final codec = AnimatedImageCodec(native, targetWidth: 80, targetHeight: 48);
    final beforePause = codec.getNextFrame();
    await Future<void>.delayed(Duration.zero);
    codec.pause();
    final afterPause = codec.getNextFrame();
    native.gate.complete();
    for (final frame in await Future.wait([beforePause, afterPause])) {
      frame.image.dispose();
    }
    for (var index = 0; index < 4; index++) {
      (await codec.getNextFrame()).image.dispose();
    }
    expect(native.decodes, 5);
    expect(AnimatedImageCodec.cachedBytes, 80 * 48 * 4 * 4);
    codec.dispose();
    expect(AnimatedImageCodec.cachedBytes, 0);
  });

  test('multiple animations share a strict global frame budget', () async {
    final data = await File('test/fixtures/animated.webp').readAsBytes();
    final codecs = <AnimatedImageCodec>[];
    for (var index = 0; index < 3; index++) {
      final native = _CountingCodec(await ui.instantiateImageCodec(data),
          reportedFrames: 400);
      final codec = AnimatedImageCodec(native);
      codecs.add(codec);
      (await codec.getNextFrame()).image.dispose();
    }
    expect(AnimatedImageCodec.cachedBytes, 2 * 160 * 96 * 4 * 400);
    expect(AnimatedImageCodec.cachedBytes, lessThanOrEqualTo(64 * 1024 * 1024));
    for (final codec in codecs) {
      codec.dispose();
    }
    expect(AnimatedImageCodec.cachedBytes, 0);
  });

  test('offscreen animations release their budget and can cache on resume',
      () async {
    final data = await File('test/fixtures/animated.webp').readAsBytes();
    final original = _CountingCodec(await ui.instantiateImageCodec(data));
    final codec = AnimatedImageCodec(original);
    for (var index = 0; index < 4; index++) {
      (await codec.getNextFrame()).image.dispose();
    }
    expect(original.decodes, 4);
    codec.pause();
    expect(AnimatedImageCodec.cachedBytes, 0);
    for (var index = 0; index < 8; index++) {
      (await codec.getNextFrame()).image.dispose();
    }
    expect(original.decodes, 8);
    codec.dispose();
    expect(AnimatedImageCodec.cachedBytes, 0);
  });

  test('reuses a WebP loop, preserving frame durations and transparency',
      () async {
    final data = await File('test/fixtures/animated.webp').readAsBytes();
    final original = _CountingCodec(await ui.instantiateImageCodec(data));
    final codec =
        AnimatedImageCodec(original, targetWidth: 80, targetHeight: 48);
    final pixels = <List<int>>[];
    for (var index = 0; index < 12; index++) {
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 80);
      expect(frame.image.height, 48);
      expect(frame.duration.inMilliseconds, [40, 60, 80, 100][index % 4]);
      final bytes = (await frame.image.toByteData())!.buffer.asUint8List();
      expect(bytes[3], 0); // Transparent corner survives resizing and caching.
      if (index < 4) {
        pixels.add(bytes.toList());
      } else {
        expect(bytes, pixels[index % 4]);
      }
      frame.image.dispose();
    }
    expect(original.decodes, 4);
    expect(AnimatedImageCodec.cachedBytes, 80 * 48 * 4 * 4);
    codec.dispose();
    expect(original.disposed, isTrue);
    expect(AnimatedImageCodec.cachedBytes, 0);
  });

  test('oversized animations stream without allocating a whole-loop cache',
      () async {
    final data = await File('test/fixtures/animated.webp').readAsBytes();
    final original = _CountingCodec(await ui.instantiateImageCodec(data),
        reportedFrames: 10000);
    final codec = AnimatedImageCodec(original);
    for (var index = 0; index < 8; index++) {
      (await codec.getNextFrame()).image.dispose();
    }
    expect(original.decodes, 8);
    expect(AnimatedImageCodec.cachedBytes, 0);
    codec.dispose();
  });

  test('memory pressure releases cached pixels and playback continues',
      () async {
    final data = await File('test/fixtures/animated.webp').readAsBytes();
    final original = _CountingCodec(await ui.instantiateImageCodec(data));
    final codec = AnimatedImageCodec(original);
    for (var index = 0; index < 4; index++) {
      (await codec.getNextFrame()).image.dispose();
    }
    expect(AnimatedImageCodec.cachedBytes, greaterThan(0));
    TestWidgetsFlutterBinding.instance.handleMemoryPressure();
    expect(AnimatedImageCodec.cachedBytes, 0);
    (await codec.getNextFrame()).image.dispose();
    expect(original.decodes, 5);
    codec.dispose();
  });
}

class _CountingCodec implements ui.Codec {
  _CountingCodec(this.codec, {this.reportedFrames});

  final ui.Codec codec;
  final int? reportedFrames;
  int decodes = 0;
  bool disposed = false;

  @override
  int get frameCount => reportedFrames ?? codec.frameCount;
  @override
  int get repetitionCount => codec.repetitionCount;

  @override
  Future<ui.FrameInfo> getNextFrame() {
    decodes++;
    return codec.getNextFrame();
  }

  @override
  void dispose() {
    disposed = true;
    codec.dispose();
  }
}

class _GatedCodec extends _CountingCodec {
  _GatedCodec(super.codec);
  final gate = Completer<void>();

  @override
  Future<ui.FrameInfo> getNextFrame() async {
    final frame = await super.getNextFrame();
    await gate.future;
    return frame;
  }
}
