part of pica_reader;

class ComicImage extends StatelessWidget {
  ComicImage({
    required ImageProvider image,
    super.key,
    double scale = 1.0,
    this.semanticLabel,
    this.excludeFromSemantics = false,
    this.width,
    this.height,
    this.preloadExtent = 0,
    this.color,
    this.opacity,
    this.colorBlendMode,
    this.fit,
    this.alignment = Alignment.center,
    this.repeat = ImageRepeat.noRepeat,
    this.centerSlice,
    this.matchTextDirection = false,
    this.gaplessPlayback = false,
    this.filterQuality = FilterQuality.medium,
    this.zoomController,
    this.isAntiAlias = false,
    Map<String, String>? headers,
    int? cacheWidth,
    int? cacheHeight,
  }) : image = ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, image);

  final ImageProvider image;
  final PhotoViewController? zoomController;
  final String? semanticLabel;
  final bool excludeFromSemantics;
  final double? width;
  final double? height;
  final double preloadExtent;
  final bool gaplessPlayback;
  final bool matchTextDirection;
  final Rect? centerSlice;
  final ImageRepeat repeat;
  final AlignmentGeometry alignment;
  final BoxFit? fit;
  final BlendMode? colorBlendMode;
  final FilterQuality filterQuality;
  final Animation<double>? opacity;
  final Color? color;
  final bool isAntiAlias;

  // Keep layout stable when scrolling back to a page, without retaining pixels.
  static final _sizes = <ImageProvider, Size>{};

  static void clear() {
    _sizes.clear();
    AnimatedImageCodec.clearCache();
  }

  @override
  Widget build(BuildContext context) {
    final displayWidth = width ?? MediaQuery.sizeOf(context).width;
    final cached = _sizes[image];
    final placeholderHeight = cached == null
        ? 300.0
        : (cached.height * displayWidth / cached.width).ceilToDouble();
    return ImageDisplay(
      image: image,
      width: displayWidth,
      // The continuous reader follows the actual aspect ratio of every page.
      fit: fit,
      alignment: alignment,
      color: color,
      opacity: opacity,
      colorBlendMode: colorBlendMode,
      repeat: repeat,
      centerSlice: centerSlice,
      matchTextDirection: matchTextDirection,
      gaplessPlayback: gaplessPlayback,
      filterQuality: filterQuality,
      isAntiAlias: isAntiAlias,
      semanticLabel: semanticLabel,
      excludeFromSemantics: excludeFromSemantics,
      resizeStatic: false,
      deferOffscreenLoading: true,
      preloadExtent: preloadExtent,
      zoomController: zoomController,
      onImage: (size) {
        if (_sizes.length >= 500) _sizes.remove(_sizes.keys.first);
        _sizes[image] = size;
      },
      placeholderBuilder: (context, progress) => SizedBox(
        width: displayWidth,
        height: placeholderHeight,
        child: ImageLoadingIndicator(progress: progress),
      ),
      errorBuilder: (context, error, retry) => SizedBox(
        height: 300,
        child: Column(
          children: [
            Expanded(child: Center(child: Text(error.toString(), maxLines: 3))),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Listener(
                onPointerDown: (_) {
                  TapController.ignoreNextTap = true;
                  retry();
                },
                child: const SizedBox(
                  width: 84,
                  height: 36,
                  child: Center(
                      child:
                          Text('Retry', style: TextStyle(color: Colors.blue))),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
