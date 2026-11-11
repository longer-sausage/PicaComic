import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:pica_comic/components/image_display.dart';
import 'package:pica_comic/foundation/image_loader/animated_image_codec.dart';

void main() {
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  testWidgets(
      'animations larger than the image cache can pause and resume safely',
      (tester) async {
    final cache = PaintingBinding.instance.imageCache;
    final originalLimit = cache.maximumSizeBytes;
    cache.maximumSizeBytes = 1;
    addTearDown(() => cache.maximumSizeBytes = originalLimit);
    final image =
        MemoryImage(File('test/fixtures/animated.webp').readAsBytesSync());
    Widget build(bool enabled) => MaterialApp(
            home: TickerMode(
          enabled: enabled,
          child:
              Center(child: ImageDisplay(image: image, width: 80, height: 48)),
        ));
    for (var cycle = 0; cycle < 2; cycle++) {
      await tester.pumpWidget(build(true));
      for (var attempt = 0;
          attempt < 30 && AnimatedImageCodec.cachedBytes == 0;
          attempt++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(AnimatedImageCodec.cachedBytes, greaterThan(0));
      await tester.pumpWidget(build(false));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      expect(AnimatedImageCodec.cachedBytes, 0);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('repeated pauses release animation caches on every cycle',
      (tester) async {
    final image =
        MemoryImage(File('test/fixtures/animated.webp').readAsBytesSync());
    Widget build(bool enabled) => MaterialApp(
            home: TickerMode(
          enabled: enabled,
          child:
              Center(child: ImageDisplay(image: image, width: 80, height: 48)),
        ));
    for (var cycle = 0; cycle < 2; cycle++) {
      await tester.pumpWidget(build(true));
      for (var attempt = 0;
          attempt < 30 && AnimatedImageCodec.cachedBytes == 0;
          attempt++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(AnimatedImageCodec.cachedBytes, greaterThan(0));
      await tester.pumpWidget(build(false));
      await tester.pump();
      expect(AnimatedImageCodec.cachedBytes, 0);
      for (var attempt = 0;
          attempt < 30 && PaintingBinding.instance.imageCache.currentSize > 0;
          attempt++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(PaintingBinding.instance.imageCache.currentSize, 0);
    }
    await tester.pumpWidget(const SizedBox());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  });

  testWidgets('fill-sized thumbnails decode using finite layout constraints',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(() async {
      final image = await _image(Colors.red, width: 160, height: 96);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      image.dispose();
      return bytes;
    });
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
      width: 40,
      height: 40,
      child: ImageDisplay(
          image: MemoryImage(bytes!),
          width: double.infinity,
          height: double.infinity),
    ))));
    final pixels = tester.allRenderObjects.whereType<RenderImage>().single;
    for (var attempt = 0; attempt < 30 && pixels.image == null; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect([pixels.image!.width, pixels.image!.height], [64, 39]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed image can evict its wrapper key and retry',
      (tester) async {
    final provider = _FlakyImageProvider();
    VoidCallback? retry;
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: ImageDisplay(
      image: provider,
      width: 100,
      height: 100,
      errorBuilder: (_, error, callback) {
        retry = callback;
        return const Text('failed');
      },
    ))));
    await tester.pump();
    expect(find.text('failed'), findsOneWidget);
    expect(retry, isNotNull);
    retry!();
    await tester.pump();
    expect(provider.loads, 2);
    provider.completer
        .emit((await tester.runAsync(() => _image(Colors.blue)))!);
    await tester.pump();
    expect(find.text('failed'), findsNothing);
    expect(tester.allRenderObjects.whereType<RenderImage>().single.image,
        isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('animation frames update pixels without rebuilding image state',
      (tester) async {
    final provider = _ManualImageProvider();
    var sizeNotifications = 0;
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: ImageDisplay(
      image: provider,
      width: 100,
      height: 100,
      onImage: (_) => sizeNotifications++,
    ))));
    final first = await tester.runAsync(() => _image(Colors.red));
    provider.completer.emit(first!);
    await tester.pump();
    await tester.pump();
    final imageElement = tester.element(find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_StreamImageDisplay'));
    expect(sizeNotifications, 1);
    final second = await tester.runAsync(() => _image(Colors.blue));
    provider.completer.emit(second!);
    expect(imageElement.dirty, isFalse);
    final renderImage = tester.allRenderObjects.whereType<RenderImage>().single;
    expect(renderImage.image!.isCloneOf(second), isTrue);
    await tester.pump();
    expect(sizeNotifications, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('changing pages cancels pending animation resolution updates',
      (tester) async {
    final animation = _ManualImageProvider();
    final still = _ManualImageProvider();
    final controller = PhotoViewController(initialScale: 1);
    Widget build(ImageProvider image) => MaterialApp(
          home: Center(
            child: ImageDisplay(
              image: image,
              width: 64,
              height: 64,
              resizeStatic: false,
              zoomController: controller,
            ),
          ),
        );
    await tester.pumpWidget(build(animation));
    for (var frame = 0; frame < 2; frame++) {
      animation.completer
          .emit((await tester.runAsync(() => _image(Colors.red)))!);
      await tester.pump();
    }
    controller.scale = 2;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(build(still));
    still.completer.emit((await tester.runAsync(() => _image(Colors.blue)))!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(animation.loads, 1);
    expect(still.loads, 1);
    controller.scale = 3;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(still.loads, 1, reason: 'The new page is static');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('scrolling outside a nested viewport pauses and resumes playback',
      (tester) async {
    final provider = _ManualImageProvider();
    final controller = ScrollController();
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
      width: 200,
      height: 100,
      child: SingleChildScrollView(
        controller: controller,
        child: Column(children: [
          ImageDisplay(image: provider, width: 100, height: 100),
          const SizedBox(height: 1000),
        ]),
      ),
    ))));
    provider.completer.emit((await tester.runAsync(() => _image(Colors.red)))!);
    await tester.pump();
    await tester.pump();
    expect(provider.completer.hasListeners, isTrue);
    controller.jumpTo(150);
    await tester.pump();
    await tester.pump();
    expect(provider.completer.hasListeners, isFalse);
    controller.jumpTo(0);
    await tester.pump();
    await tester.pump();
    expect(provider.completer.hasListeners, isTrue);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('background lifecycle and TickerMode stop frame listeners',
      (tester) async {
    final provider = _ManualImageProvider();
    Widget build(bool enabled) => MaterialApp(
            home: TickerMode(
          enabled: enabled,
          child: Center(
              child: ImageDisplay(image: provider, width: 100, height: 100)),
        ));
    await tester.pumpWidget(build(true));
    provider.completer.emit((await tester.runAsync(() => _image(Colors.red)))!);
    await tester.pump();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(provider.completer.hasListeners, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(provider.completer.hasListeners, isTrue);
    await tester.pumpWidget(build(false));
    await tester.pump();
    expect(provider.completer.hasListeners, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a sibling layout change resumes a previously invisible image',
      (tester) async {
    final provider = _ManualImageProvider();
    final spacer = ValueNotifier(150.0);
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 200,
          height: 100,
          child: SingleChildScrollView(
            child: Column(children: [
              ValueListenableBuilder<double>(
                valueListenable: spacer,
                builder: (_, height, __) => SizedBox(height: height),
              ),
              ImageDisplay(image: provider, width: 100, height: 100),
            ]),
          ),
        ),
      ),
    ));
    provider.completer.emit((await tester.runAsync(() => _image(Colors.red)))!);
    await tester.pump();
    await tester.pump();
    expect(provider.completer.hasListeners, isFalse);
    spacer.value = 0;
    await tester.pump();
    await tester.pump();
    expect(provider.completer.hasListeners, isTrue);
    expect(tester.allRenderObjects.whereType<RenderImage>().single.image,
        isNotNull);
    await tester.pumpWidget(const SizedBox());
    spacer.dispose();
  });

  testWidgets('reader images only start decoding when they enter the viewport',
      (tester) async {
    final provider = _ManualImageProvider();
    final controller = ScrollController();
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 100,
          height: 100,
          child: SingleChildScrollView(
            controller: controller,
            child: Column(children: [
              const SizedBox(height: 150),
              ImageDisplay(
                image: provider,
                width: 100,
                height: 100,
                deferOffscreenLoading: true,
              ),
            ]),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(provider.loads, 0);
    controller.jumpTo(150);
    await tester.pump();
    await tester.pump();
    expect(provider.loads, 1);
    provider.completer.emit((await tester.runAsync(() => _image(Colors.red)))!);
    await tester.pump();
    expect(tester.allRenderObjects.whereType<RenderImage>().single.image,
        isNotNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('a retained image resumes after a transform without scrolling',
      (tester) async {
    final provider = _ManualImageProvider();
    final offset = ValueNotifier(Offset.zero);
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: ClipRect(
          child: SizedBox(
            width: 100,
            height: 100,
            child: ValueListenableBuilder<Offset>(
              valueListenable: offset,
              builder: (_, value, child) =>
                  Transform.translate(offset: value, child: child),
              child: ImageDisplay(image: provider, width: 100, height: 100),
            ),
          ),
        ),
      ),
    ));
    provider.completer.emit((await tester.runAsync(() => _image(Colors.red)))!);
    await tester.pump();
    offset.value = const Offset(200, 0);
    await tester.pump();
    await tester.pump();
    expect(provider.completer.hasListeners, isFalse);
    offset.value = Offset.zero;
    await tester.pump();
    await tester.pump();
    expect(provider.completer.hasListeners, isTrue);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse,
        reason: 'Visibility checks must not continuously schedule idle frames');
    await tester.pumpWidget(const SizedBox());
    offset.dispose();
  });

  testWidgets('continuous lookahead prepares a first frame before scrolling',
      (tester) async {
    final image = _ManualImageProvider();
    final controller = ScrollController();
    var loadingBuilds = 0;
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 100,
          height: 100,
          child: SingleChildScrollView(
            controller: controller,
            child: Column(children: [
              const SizedBox(height: 150),
              ImageDisplay(
                image: image,
                width: 100,
                height: 100,
                deferOffscreenLoading: true,
                preloadExtent: 100,
                placeholderBuilder: (_, progress) {
                  loadingBuilds++;
                  return const Text('loading');
                },
              ),
            ]),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(image.loads, 1);
    final beforeProgress = loadingBuilds;
    image.completer.progress(50, 100);
    await tester.pump();
    expect(loadingBuilds, beforeProgress,
        reason: 'Offscreen download progress should not rebuild the reader');
    image.completer.emit((await tester.runAsync(() => _image(Colors.red)))!);
    await tester.pump();
    await tester.pump();
    expect(image.completer.hasListeners, isFalse,
        reason: 'Lookahead only prepares a first frame, then pauses playback');
    expect(tester.allRenderObjects.whereType<RenderImage>().single.image,
        isNotNull);
    controller.jumpTo(150);
    await tester.pump();
    await tester.pump();
    expect(image.loads, 1, reason: 'The entering page is already decoded');
    expect(image.completer.hasListeners, isTrue);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('continuous pages decode while scroll deferral is recommended',
      (tester) async {
    final image = _ManualImageProvider();
    await tester.pumpWidget(MaterialApp(
      home: SingleChildScrollView(
        physics: const _DeferImagesPhysics(),
        child: ImageDisplay(
          image: image,
          width: 100,
          height: 100,
          deferOffscreenLoading: true,
          preloadExtent: 100,
        ),
      ),
    ));
    await tester.pump();
    expect(image.loads, 1,
        reason: 'Ready reading pages must not wait for a fling to stop');
    image.completer.emit((await tester.runAsync(() => _image(Colors.red)))!);
    await tester.pump();
    expect(tester.allRenderObjects.whereType<RenderImage>().single.image,
        isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('offscreen animated lookahead keeps one frame and resumes safely',
      (tester) async {
    final image =
        MemoryImage(File('test/fixtures/animated.webp').readAsBytesSync());
    final controller = ScrollController();
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 100,
          height: 100,
          child: SingleChildScrollView(
            controller: controller,
            child: Column(children: [
              const SizedBox(height: 150),
              ImageDisplay(
                image: image,
                width: 100,
                height: 100,
                deferOffscreenLoading: true,
                preloadExtent: 100,
              ),
            ]),
          ),
        ),
      ),
    ));
    final pixels = tester.allRenderObjects.whereType<RenderImage>().single;
    for (var attempt = 0; attempt < 40 && pixels.image == null; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(pixels.image, isNotNull);
    for (var frame = 0; frame < 10; frame++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(AnimatedImageCodec.cachedBytes, 0,
        reason:
            'Preparing an offscreen first frame must not play the animation');
    controller.jumpTo(150);
    for (var attempt = 0;
        attempt < 40 && AnimatedImageCodec.cachedBytes == 0;
        attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(AnimatedImageCodec.cachedBytes, greaterThan(0));
    expect(pixels.image, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}

class _DeferImagesPhysics extends ScrollPhysics {
  const _DeferImagesPhysics();

  @override
  _DeferImagesPhysics applyTo(ScrollPhysics? ancestor) => this;

  @override
  bool recommendDeferredLoading(
          double velocity, ScrollMetrics metrics, BuildContext context) =>
      true;
}

Future<ui.Image> _image(Color color, {int width = 16, int height = 16}) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(color, ui.BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

class _ManualImageProvider extends ImageProvider<_ManualImageProvider> {
  final completer = _ManualCompleter();
  int loads = 0;

  @override
  Future<_ManualImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
      _ManualImageProvider key, ImageDecoderCallback decode) {
    loads++;
    return completer;
  }
}

class _ManualCompleter extends ImageStreamCompleter {
  void emit(ui.Image image) => setImage(ImageInfo(image: image));

  void progress(int loaded, int total) => reportImageChunkEvent(ImageChunkEvent(
      cumulativeBytesLoaded: loaded, expectedTotalBytes: total));
}

class _FlakyImageProvider extends ImageProvider<_FlakyImageProvider> {
  final completer = _ManualCompleter();
  int loads = 0;

  @override
  Future<_FlakyImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
      _FlakyImageProvider key, ImageDecoderCallback decode) {
    loads++;
    if (loads == 1) {
      return MultiFrameImageStreamCompleter(
        codec: Future<ui.Codec>.error(StateError('failed')),
        scale: 1,
      );
    }
    return completer;
  }
}
