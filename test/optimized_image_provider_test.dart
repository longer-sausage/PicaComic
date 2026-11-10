import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/image_loader/optimized_image_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  test('thumbnail resizing respects contain and cover without upscaling',
      () async {
    final bytes = await _png();
    final contain = await _firstFrame(OptimizedImageProvider(
      MemoryImage(bytes),
      width: 80,
      height: 80,
    ));
    expect([contain.image.width, contain.image.height], [80, 48]);
    contain.dispose();
    final cover = await _firstFrame(OptimizedImageProvider(
      MemoryImage(bytes),
      width: 80,
      height: 80,
      fit: BoxFit.cover,
    ));
    expect([cover.image.width, cover.image.height], [134, 80]);
    cover.dispose();
    final full = await _firstFrame(OptimizedImageProvider(
      MemoryImage(bytes),
      width: 1000,
      height: 1000,
    ));
    expect([full.image.width, full.image.height], [320, 192]);
    full.dispose();
  });

  test('reading still images keeps full resolution for zooming', () async {
    final info = await _firstFrame(OptimizedImageProvider(
      MemoryImage(await _png()),
      width: 80,
      height: 80,
      resizeStatic: false,
    ));
    expect([info.image.width, info.image.height], [320, 192]);
    info.dispose();
  });

  testWidgets('an explicit animation cache width keeps the source aspect ratio',
      (tester) async {
    final bytes = File('test/fixtures/animated.webp').readAsBytesSync();
    ImageInfo? info;
    final loaded = _firstFrame(OptimizedImageProvider(
      ResizeImage(MemoryImage(bytes), width: 80),
    )).then((value) => info = value);
    for (var attempt = 0; attempt < 30 && info == null; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(info, isNotNull);
    await loaded;
    expect([info!.image.width, info!.image.height], [80, 48]);
    info!.dispose();
  });
}

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff336699), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(320, 192);
  picture.dispose();
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
      .buffer
      .asUint8List();
  image.dispose();
  return bytes;
}

Future<ImageInfo> _firstFrame(ImageProvider provider) async {
  final result = Completer<ImageInfo>();
  final stream = provider.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener((info, synchronous) {
    if (result.isCompleted) {
      info.dispose();
    } else {
      result.complete(info);
    }
  },
      onError: (Object error, StackTrace? stack) =>
          result.completeError(error, stack));
  stream.addListener(listener);
  try {
    return await result.future;
  } finally {
    stream.removeListener(listener);
  }
}
