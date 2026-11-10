import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:photo_view/photo_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/components/zoomable_image.dart';

void main() {
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  testWidgets('zooming a still image does not start another decode',
      (tester) async {
    final provider = _ManualProvider();
    final controller = PhotoViewController();
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
      width: 300,
      height: 200,
      child: ZoomableImage(image: provider, controller: controller),
    ))));
    provider.completer.emit((await tester.runAsync(_image))!);
    await tester.pump();
    await tester.pump();
    controller.onDoubleClick?.call();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(controller.scale, greaterThan(1));
    expect(provider.loads, 1);
    expect(
        tester.allRenderObjects.whereType<RenderImage>().single.filterQuality,
        FilterQuality.medium);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('image dimensions settle once and double-tap zoom works',
      (tester) async {
    final provider = _ManualProvider();
    final controller = PhotoViewController();
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
      width: 300,
      height: 200,
      child: ZoomableImage(image: provider, controller: controller),
    ))));
    provider.completer.emit((await tester.runAsync(_image))!);
    await tester.pump();
    await tester.pump();
    final photoView = tester.widget<PhotoView>(find.byType(PhotoView));
    expect(photoView.childSize, const Size(300, 180));
    expect(provider.loads, 1);
    final state = tester.element(find.byType(ZoomableImage));
    provider.completer.emit((await tester.runAsync(_image))!);
    expect(state.dirty, isFalse);
    // The reader's TapController invokes this callback for double taps.
    controller.onDoubleClick?.call();
    await tester.pumpAndSettle();
    expect(controller.scale, greaterThan(1));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(provider.loads, 2); // Only refine after zooming has settled.
    expect(controller.scale, greaterThan(1));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('a page swipe still reaches the next image', (tester) async {
    final providers = [_ManualProvider(), _ManualProvider()];
    final pages = PageController();
    await tester.pumpWidget(MaterialApp(
        home: PhotoViewGestureDetectorScope(
      axis: Axis.horizontal,
      child: PageView.builder(
        controller: pages,
        itemCount: 2,
        itemBuilder: (_, index) => ZoomableImage(image: providers[index]),
      ),
    )));
    for (final provider in providers) {
      provider.completer.emit((await tester.runAsync(_image))!);
    }
    await tester.pump();
    await tester.pump();
    await tester.drag(find.byType(PageView), const Offset(-700, 0));
    await tester.pumpAndSettle();
    expect(pages.page, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    pages.dispose();
  });
}

Future<ui.Image> _image() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(Colors.red, ui.BlendMode.src);
  final picture = recorder.endRecording();
  final result = await picture.toImage(160, 96);
  picture.dispose();
  return result;
}

class _ManualProvider extends ImageProvider<_ManualProvider> {
  final completer = _ManualCompleter();
  int loads = 0;

  @override
  Future<_ManualProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
      _ManualProvider key, ImageDecoderCallback decode) {
    loads++;
    return completer;
  }
}

class _ManualCompleter extends ImageStreamCompleter {
  void emit(ui.Image image) => setImage(ImageInfo(image: image));
}
