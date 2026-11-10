// Run explicitly: flutter test test/animated_image_benchmark.dart --reporter expanded
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/image_loader/animated_image_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('compare eight concurrent WebP decoders over six loops', () async {
    final bytes =
        File('test/fixtures/animated_benchmark.webp').readAsBytesSync();
    final warmup = await ui.instantiateImageCodec(bytes);
    (await warmup.getNextFrame()).image.dispose();
    warmup.dispose();
    final baseline = await _measure(bytes, cached: false);
    final optimized = await _measure(bytes, cached: true);
    // Timing is diagnostic. Native decode count is a deterministic regression check.
    expect(
        optimized['nativeDecodes'], (baseline['nativeDecodes']! / 6).round());
    // ignore: avoid_print
    print(jsonEncode({'baseline': baseline, 'optimized': optimized}));
  });
}

Future<Map<String, int>> _measure(Uint8List bytes,
    {required bool cached}) async {
  final native = await Future.wait(List.generate(
      8, (_) async => _CountingCodec(await ui.instantiateImageCodec(bytes))));
  final codecs = <ui.Codec>[
    for (final codec in native)
      if (cached)
        AnimatedImageCodec(codec, targetWidth: 320, targetHeight: 180)
      else
        codec,
  ];
  final clock = Stopwatch()..start();
  var firstLoopMicros = 0;
  try {
    for (var frame = 0; frame < native.first.frameCount * 6; frame++) {
      final frames =
          await Future.wait(codecs.map((codec) => codec.getNextFrame()));
      for (final frame in frames) {
        frame.image.dispose();
      }
      if (frame == native.first.frameCount - 1) {
        firstLoopMicros = clock.elapsedMicroseconds;
      }
    }
    return {
      'firstLoopMicros': firstLoopMicros,
      'remainingFiveLoopsMicros': clock.elapsedMicroseconds - firstLoopMicros,
      'nativeDecodes': native.fold(0, (count, codec) => count + codec.decodes),
      'reservedFrameBytes': AnimatedImageCodec.cachedBytes,
    };
  } finally {
    for (final codec in codecs) {
      codec.dispose();
    }
    expect(AnimatedImageCodec.cachedBytes, 0);
  }
}

class _CountingCodec implements ui.Codec {
  _CountingCodec(this.codec);
  final ui.Codec codec;
  int decodes = 0;
  @override
  int get frameCount => codec.frameCount;
  @override
  int get repetitionCount => codec.repetitionCount;
  @override
  Future<ui.FrameInfo> getNextFrame() {
    decodes++;
    return codec.getNextFrame();
  }

  @override
  void dispose() => codec.dispose();
}
