import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

import 'image_display.dart';

/// Keeps PhotoView's gestures while using one image listener and a render-only
/// animation path. The dependency's image wrapper rebuilds on every frame.
class ZoomableImage extends StatefulWidget {
  const ZoomableImage({
    super.key,
    required this.image,
    this.controller,
    this.backgroundDecoration,
    this.heroAttributes,
    this.fit = BoxFit.contain,
    this.minScale,
    this.loadingBuilder,
    this.errorBuilder,
  });

  final ImageProvider image;
  final PhotoViewController? controller;
  final BoxDecoration? backgroundDecoration;
  final PhotoViewHeroAttributes? heroAttributes;
  final BoxFit fit;
  final dynamic minScale;
  final Widget Function(BuildContext, ImageChunkEvent?)? loadingBuilder;
  final Widget Function(BuildContext, Object, VoidCallback)? errorBuilder;

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage> {
  Size? _imageSize;
  PhotoViewController? _ownedController;

  PhotoViewController get _controller =>
      widget.controller ?? (_ownedController ??= PhotoViewController());

  @override
  void didUpdateWidget(ZoomableImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image) {
      _imageSize = null;
    }
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final viewport = constraints.biggest;
      var displaySize = viewport;
      if (_imageSize != null) {
        final widthScale = viewport.width / _imageSize!.width;
        final heightScale = viewport.height / _imageSize!.height;
        final scale = switch (widget.fit) {
          BoxFit.fitWidth => widthScale,
          BoxFit.fitHeight => heightScale,
          BoxFit.cover => math.max(widthScale, heightScale),
          _ => math.min(widthScale, heightScale),
        };
        displaySize = _imageSize! * scale;
      }
      return ClipRect(
        child: PhotoView.customChild(
          controller: _controller,
          backgroundDecoration: widget.backgroundDecoration,
          heroAttributes: widget.heroAttributes,
          childSize: displaySize,
          initialScale: 1.0,
          minScale: widget.minScale,
          child: ImageDisplay(
            image: widget.image,
            width: displaySize.width,
            height: displaySize.height,
            decodeSize: viewport,
            zoomController: _controller,
            fit: widget.fit,
            filterQuality: FilterQuality.medium,
            resizeStatic: false,
            gaplessPlayback: true,
            onImage: (size) {
              if (_imageSize != size) setState(() => _imageSize = size);
            },
            placeholderBuilder: widget.loadingBuilder ??
                (_, progress) =>
                    const Center(child: CircularProgressIndicator()),
            errorBuilder: widget.errorBuilder,
          ),
        ),
      );
    });
  }
}
