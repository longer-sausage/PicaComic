part of 'components.dart';

class AnimatedImage extends StatelessWidget {
  /// Fade in the first frame; subsequent animation frames only repaint.
  AnimatedImage({
    required ImageProvider image,
    super.key,
    double scale = 1.0,
    this.semanticLabel,
    this.excludeFromSemantics = false,
    this.width,
    this.height,
    this.color,
    this.opacity,
    this.colorBlendMode,
    this.fit,
    this.alignment = Alignment.center,
    this.repeat = ImageRepeat.noRepeat,
    this.centerSlice,
    this.matchTextDirection = false,
    this.gaplessPlayback = false,
    this.filterQuality = FilterQuality.low,
    this.isAntiAlias = false,
    Map<String, String>? headers,
    int? cacheWidth,
    int? cacheHeight,
  }) : image = ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, image);

  final ImageProvider image;
  final String? semanticLabel;
  final bool excludeFromSemantics;
  final double? width;
  final double? height;
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

  static void clear() => AnimatedImageCodec.clearCache();

  @override
  Widget build(BuildContext context) {
    return ImageDisplay(
      image: image,
      semanticLabel: semanticLabel,
      excludeFromSemantics: excludeFromSemantics,
      width: width,
      height: height,
      color: color,
      opacity: opacity,
      colorBlendMode: colorBlendMode,
      fit: appdata.settings[66] == '0' ? BoxFit.cover : BoxFit.contain,
      alignment: alignment,
      repeat: repeat,
      centerSlice: centerSlice,
      matchTextDirection: matchTextDirection,
      gaplessPlayback: gaplessPlayback,
      filterQuality: filterQuality,
      isAntiAlias: isAntiAlias,
      fadeInDuration: const Duration(milliseconds: 200),
    );
  }
}
