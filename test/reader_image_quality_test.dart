import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:pica_comic/components/zoomable_image.dart';
import 'package:pica_comic/pages/reader/comic_reading_page.dart';

void main() {
  tearDown(() {
    ComicImage.clear();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  for (final mode in _ReaderMode.values) {
    testWidgets(
        '${mode.name} still pages retain full resolution and medium sampling',
        (tester) async {
      _setViewport(tester);
      final bytes = (await tester.runAsync(_png))!;
      final images = List.generate(mode == _ReaderMode.twoPage ? 2 : 1,
          (_) => _CountingMemoryImage(Uint8List.fromList(bytes)));
      final controller = PhotoViewController();
      await tester.pumpWidget(_reader(images, controller, mode));
      await _waitFor(
          tester, () => _pixels(tester).every((p) => p.image != null));
      for (final pixels in _pixels(tester)) {
        expect([pixels.image!.width, pixels.image!.height], [320, 192]);
        expect(pixels.filterQuality, FilterQuality.medium);
      }

      controller.scale = 2.5;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(images.map((image) => image.loads), everyElement(1));
      expect(_pixels(tester).map((p) => p.image!.width), everyElement(320));
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets(
        '${mode.name} animated pages refine pixels after zooming settles',
        (tester) async {
      _setViewport(tester);
      final bytes = File('test/fixtures/animated.webp').readAsBytesSync();
      final images = List.generate(mode == _ReaderMode.twoPage ? 2 : 1,
          (_) => _CountingMemoryImage(Uint8List.fromList(bytes)));
      final controller = PhotoViewController();
      await tester.pumpWidget(_reader(images, controller, mode));
      final initialWidth = mode == _ReaderMode.twoPage ? 64 : 128;
      await _waitFor(
          tester,
          () => _pixels(tester)
              .every((pixels) => pixels.image?.width == initialWidth));
      // Deliver multiple real WebP frames so the renderer detects animation.
      for (var frame = 0; frame < 8; frame++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump(const Duration(milliseconds: 40));
      }

      controller.scale = 1.6;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      controller.scale = 2;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // A pan must not delay the refinement after the last scale change.
      controller.position = const Offset(5, 0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 149));
      expect(images.map((image) => image.loads), everyElement(1));
      await tester.pump(const Duration(milliseconds: 1));
      expect(images.map((image) => image.loads), everyElement(2));
      expect(_pixels(tester).map((pixels) => pixels.image),
          everyElement(isNotNull),
          reason: 'Keep the previous frame while the higher resolution loads');

      final refinedWidth = mode == _ReaderMode.twoPage ? 128 : 160;
      await _waitFor(
          tester,
          () => _pixels(tester)
              .every((pixels) => pixels.image?.width == refinedWidth));
      expect(controller.scale, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }
}

void _setViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(128, 200);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

List<RenderImage> _pixels(WidgetTester tester) =>
    tester.allRenderObjects.whereType<RenderImage>().toList();

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 60 && !ready(); attempt++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue);
}

Widget _reader(List<ImageProvider> images, PhotoViewController controller,
    _ReaderMode mode) {
  final child = mode == _ReaderMode.singlePage
      ? ZoomableImage(image: images.single, controller: controller)
      : mode == _ReaderMode.continuous
          ? PhotoView.customChild(
              controller: controller,
              minScale: 1.0,
              maxScale: 2.5,
              strictScale: true,
              child: SingleChildScrollView(
                child: ComicImage(
                  image: images.single,
                  width: 128,
                  fit: BoxFit.cover,
                  zoomController: controller,
                ),
              ),
            )
          : PhotoViewGallery(pageOptions: [
              PhotoViewGalleryPageOptions.customChild(
                controller: controller,
                child: Row(
                  children: [
                    for (var page = 0; page < images.length; page++)
                      Expanded(
                        child: ComicImage(
                          image: images[page],
                          width: 64,
                          fit: BoxFit.contain,
                          alignment: page == 0
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          zoomController: controller,
                        ),
                      ),
                  ],
                ),
              ),
            ]);
  return MaterialApp(home: child);
}

enum _ReaderMode { continuous, twoPage, singlePage }

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(Colors.red, ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(320, 192);
  picture.dispose();
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
      .buffer
      .asUint8List();
  image.dispose();
  return bytes;
}

class _CountingMemoryImage extends MemoryImage {
  _CountingMemoryImage(super.bytes);

  final _counter = _LoadCounter();
  int get loads => _counter.value;

  @override
  ImageStreamCompleter loadImage(MemoryImage key, ImageDecoderCallback decode) {
    _counter.value++;
    return super.loadImage(key, decode);
  }
}

class _LoadCounter {
  int value = 0;
}
