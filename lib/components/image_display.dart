import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:photo_view/photo_view.dart';

import '../foundation/image_loader/optimized_image_provider.dart';

/// An image whose animation updates RenderImage directly, without rebuilding
/// its widget tree for every decoded frame.
class ImageDisplay extends StatefulWidget {
  const ImageDisplay({
    super.key,
    required this.image,
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.color,
    this.opacity,
    this.colorBlendMode,
    this.repeat = ImageRepeat.noRepeat,
    this.centerSlice,
    this.matchTextDirection = false,
    this.gaplessPlayback = false,
    this.filterQuality = FilterQuality.low,
    this.isAntiAlias = false,
    this.semanticLabel,
    this.excludeFromSemantics = false,
    this.resizeStatic = true,
    this.decodeSize,
    this.zoomController,
    this.fadeInDuration = Duration.zero,
    this.placeholderBuilder,
    this.errorBuilder,
    this.onImage,
    this.onAnimationDetected,
  });

  final ImageProvider image;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final Color? color;
  final Animation<double>? opacity;
  final BlendMode? colorBlendMode;
  final ImageRepeat repeat;
  final Rect? centerSlice;
  final bool matchTextDirection;
  final bool gaplessPlayback;
  final FilterQuality filterQuality;
  final bool isAntiAlias;
  final String? semanticLabel;
  final bool excludeFromSemantics;
  final bool resizeStatic;

  /// Logical display bounds, independent of a zoomable image's child size.
  final Size? decodeSize;

  /// Refines animated frames after this controller's zoom has settled.
  /// Static reading images already retain their full source resolution.
  final PhotoViewController? zoomController;
  final Duration fadeInDuration;
  final Widget Function(BuildContext, ImageChunkEvent?)? placeholderBuilder;
  final Widget Function(BuildContext, Object, VoidCallback retry)? errorBuilder;
  final ValueChanged<Size>? onImage;
  final VoidCallback? onAnimationDetected;

  @override
  State<ImageDisplay> createState() => _ImageDisplayState();
}

class _ImageDisplayState extends State<ImageDisplay> {
  StreamSubscription<PhotoViewControllerValue>? _scaleSubscription;
  Timer? _resizeTimer;
  double _decodeScale = 1;
  double? _lastZoomScale;
  bool _isAnimated = false;

  void _listenForZoom() {
    final controller = widget.zoomController;
    if (!_isAnimated || controller == null) return;
    _scaleSubscription = controller.outputStateStream.listen((value) {
      _updateDecodeScale(value.scale);
    });
    _updateDecodeScale(controller.scale);
  }

  void _updateDecodeScale(double? value) {
    if (value == null || !value.isFinite || value <= 0) return;
    // Panning at the same scale must not postpone resolution refinement.
    if (value == _lastZoomScale) return;
    _lastZoomScale = value;
    _resizeTimer?.cancel();
    final scale = (math.max(1.0, value) * 2).ceil() / 2;
    if (scale == _decodeScale) return;
    _resizeTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _decodeScale = scale);
    });
  }

  void _handleAnimationDetected() {
    if (!_isAnimated) {
      _isAnimated = true;
      _listenForZoom();
    }
    widget.onAnimationDetected?.call();
  }

  void _stopListeningForZoom() {
    _scaleSubscription?.cancel();
    _scaleSubscription = null;
    _resizeTimer?.cancel();
    _lastZoomScale = null;
  }

  @override
  void didUpdateWidget(ImageDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image) {
      _stopListeningForZoom();
      _isAnimated = false;
      _decodeScale = 1;
    } else if (widget.zoomController != oldWidget.zoomController) {
      _stopListeningForZoom();
      _decodeScale = 1;
      _listenForZoom();
    }
  }

  @override
  void dispose() {
    _stopListeningForZoom();
    super.dispose();
  }

  static int? _physicalSize(double value, double pixelRatio) {
    if (!value.isFinite || value <= 0) return null;
    // Stable cache keys when a window or grid changes by a few pixels.
    return ((value * pixelRatio / 64).ceil() * 64).clamp(1, 16384);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final pixelRatio = MediaQuery.devicePixelRatioOf(context);
      final displayWidth =
          widget.width?.isFinite == true ? widget.width! : constraints.maxWidth;
      final displayHeight = widget.height?.isFinite == true
          ? widget.height!
          : constraints.maxHeight;
      return _StreamImageDisplay(
        options: widget,
        image: OptimizedImageProvider(
          widget.image,
          width: _physicalSize(
              (widget.decodeSize?.width ?? displayWidth) * _decodeScale,
              pixelRatio),
          height: _physicalSize(
              (widget.decodeSize?.height ?? displayHeight) * _decodeScale,
              pixelRatio),
          fit: widget.fit ?? BoxFit.contain,
          resizeStatic: widget.resizeStatic,
        ),
        onAnimationDetected:
            widget.zoomController != null || widget.onAnimationDetected != null
                ? _handleAnimationDetected
                : null,
      );
    });
  }
}

class _StreamImageDisplay extends StatefulWidget {
  const _StreamImageDisplay(
      {required this.options, required this.image, this.onAnimationDetected});

  final ImageDisplay options;
  final ImageProvider image;
  final VoidCallback? onAnimationDetected;

  @override
  State<_StreamImageDisplay> createState() => _StreamImageDisplayState();
}

class _StreamImageDisplayState extends State<_StreamImageDisplay> {
  final _frames = ValueNotifier<ImageInfo?>(null);
  late final _scrollContext = DisposableBuildContext(this);
  ImageStream? _stream;
  ImageProvider? _resolvedSource;
  ImageInfo? _info;
  ImageChunkEvent? _progress;
  Object? _error;
  bool _listening = false;
  bool _active = true;
  int _receivedFrames = 0;
  bool _awaitingFirstFrame = true;
  late final _listener = ImageStreamListener(
    _handleFrame,
    onChunk: _handleProgress,
    onError: (Object error, StackTrace? stack) {
      if (mounted) setState(() => _error = error);
    },
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
    _updateListening();
  }

  @override
  void didUpdateWidget(_StreamImageDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image) {
      _resolve(keepFrame: widget.options.image == oldWidget.options.image);
    }
  }

  void _resolve({bool retry = false, bool keepFrame = false}) {
    if (!_active || !TickerMode.of(context)) return;
    final stream = ScrollAwareImageProvider<Object>(
      context: _scrollContext,
      imageProvider: widget.image,
    ).resolve(createLocalImageConfiguration(context));
    if (!retry && _stream?.key == stream.key) {
      _updateListening(resolve: false);
      return;
    }
    if (_listening) _stream!.removeListener(_listener);
    _listening = false;
    _stream = stream;
    _receivedFrames = 0;
    _awaitingFirstFrame = true;
    _error = null;
    _progress = null;
    if (!widget.options.gaplessPlayback &&
        !(keepFrame && _resolvedSource == widget.options.image)) {
      _replaceFrame(null);
    }
    _resolvedSource = widget.options.image;
    _updateListening(resolve: false);
  }

  void _updateListening({bool resolve = true}) {
    final listen = _active && TickerMode.of(context);
    if (listen == _listening) return;
    if (listen && resolve) {
      // An inactive animation may have released its native decoder.
      _resolve(keepFrame: true);
      return;
    }
    if (_stream == null) return;
    if (listen) {
      _listening = true;
      _stream!.addListener(_listener);
    } else {
      _stream!.removeListener(_listener);
      _listening = false;
    }
  }

  void _handleFrame(ImageInfo info, bool synchronous) {
    final sourceKey = _stream?.key;
    if (widget.onAnimationDetected != null &&
        _receivedFrames < 2 &&
        (_receivedFrames == 0 || !synchronous)) {
      _receivedFrames++;
      if (_receivedFrames == 2) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted && _stream?.key == sourceKey) {
            widget.onAnimationDetected?.call();
          }
        });
      }
    }
    final sizeChanged = _info?.image.width != info.image.width ||
        _info?.image.height != info.image.height;
    final firstFrame = _awaitingFirstFrame;
    _awaitingFirstFrame = false;
    final rebuild =
        firstFrame || sizeChanged || _error != null || _progress != null;
    _replaceFrame(info);
    _error = null;
    _progress = null;
    if (rebuild) setState(() {});
    if ((firstFrame || sizeChanged) && widget.options.onImage != null) {
      final size =
          Size(info.image.width.toDouble(), info.image.height.toDouble());
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && _stream?.key == sourceKey) {
          widget.options.onImage?.call(size);
        }
      });
    }
  }

  void _replaceFrame(ImageInfo? info) {
    final previous = _info;
    _info = info;
    _frames.value = info;
    // The render object owns its own image handle.
    previous?.dispose();
  }

  void _handleProgress(ImageChunkEvent event) {
    if (_info == null && widget.options.placeholderBuilder != null) {
      setState(() => _progress = event);
    }
  }

  @override
  void dispose() {
    if (_listening) _stream!.removeListener(_listener);
    _scrollContext.dispose();
    _replaceFrame(null);
    _frames.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final options = widget.options;
    Widget pixels = _FrameImage(frames: _frames, options: options);
    if (options.fadeInDuration != Duration.zero) {
      pixels = AnimatedOpacity(
        opacity: _info == null ? 0 : 1,
        duration: options.fadeInDuration,
        child: pixels,
      );
    }
    Widget result = Stack(
      alignment: Alignment.center,
      children: [
        pixels,
        if (_error != null)
          options.errorBuilder?.call(context, _error!, () {
                setState(() => _resolve(retry: true));
              }) ??
              const Center(child: Icon(Icons.error)),
        if (_error == null && _info == null)
          options.placeholderBuilder?.call(context, _progress) ??
              const SizedBox(),
      ],
    );
    if (!options.excludeFromSemantics) {
      result =
          Semantics(image: true, label: options.semanticLabel, child: result);
    }
    return ImageActivity(
      onChanged: (active) {
        _active = active;
        _updateListening();
      },
      child: result,
    );
  }
}

class _FrameImage extends LeafRenderObjectWidget {
  const _FrameImage({required this.frames, required this.options});

  final ValueListenable<ImageInfo?> frames;
  final ImageDisplay options;

  @override
  RenderImage createRenderObject(BuildContext context) {
    return _RenderFrameImage(frames)..updateOptions(context, options);
  }

  @override
  void updateRenderObject(
      BuildContext context, _RenderFrameImage renderObject) {
    renderObject.updateOptions(context, options);
  }
}

class _RenderFrameImage extends RenderImage {
  _RenderFrameImage(this.frames);

  final ValueListenable<ImageInfo?> frames;

  void updateOptions(BuildContext context, ImageDisplay options) {
    width = options.width;
    height = options.height;
    color = options.color;
    opacity = options.opacity;
    colorBlendMode = options.colorBlendMode;
    fit = options.fit;
    alignment = options.alignment;
    repeat = options.repeat;
    centerSlice = options.centerSlice;
    matchTextDirection = options.matchTextDirection;
    textDirection = Directionality.maybeOf(context);
    invertColors = MediaQuery.maybeInvertColorsOf(context) ?? false;
    filterQuality = options.filterQuality;
    isAntiAlias = options.isAntiAlias;
  }

  void _updateFrame() {
    final info = frames.value;
    image = info?.image.clone();
    scale = info?.scale ?? 1;
    debugImageLabel = info?.debugLabel;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    frames.addListener(_updateFrame);
    _updateFrame();
  }

  @override
  void detach() {
    frames.removeListener(_updateFrame);
    super.detach();
  }
}

/// Pauses image streams outside scroll clips, on inactive routes, and while
/// the app is in the background. Checks are coalesced to once per scroll frame.
class ImageActivity extends StatefulWidget {
  const ImageActivity({super.key, required this.child, this.onChanged});

  final Widget child;
  final ValueChanged<bool>? onChanged;

  @override
  State<ImageActivity> createState() => _ImageActivityState();
}

class _ImageActivityState extends State<ImageActivity>
    with WidgetsBindingObserver {
  final _renderKey = GlobalKey();
  final _positions = <ScrollPosition>[];
  bool _scheduled = false;
  bool _enabled = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    for (final position in _positions) {
      position.removeListener(_scheduleCheck);
    }
    _positions.clear();
    context.visitAncestorElements((element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        final position = (element.state as ScrollableState).position;
        if (!_positions.contains(position)) {
          _positions.add(position);
          position.addListener(_scheduleCheck);
        }
      }
      return true;
    });
    _scheduleCheck();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _enabled) {
      setState(() => _enabled = false);
      widget.onChanged?.call(false);
    }
    _scheduleCheck();
  }

  @override
  void didUpdateWidget(ImageActivity oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleCheck();
  }

  @override
  void didChangeMetrics() => _scheduleCheck();

  void _scheduleCheck() {
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      final enabled =
          (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
              TickerMode.of(context) &&
              _isVisible();
      if (enabled != _enabled) {
        setState(() => _enabled = enabled);
        widget.onChanged?.call(enabled);
      }
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  bool _isVisible() {
    final box = _renderKey.currentContext?.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        box.size.isEmpty) {
      return true;
    }
    var bounds = MatrixUtils.transformRect(
        box.getTransformTo(null), Offset.zero & box.size);
    bounds = bounds.intersect(Offset.zero & MediaQuery.sizeOf(context));
    if (bounds.isEmpty) {
      return false;
    }
    RenderObject child = box;
    while (child.parent != null) {
      final parent = child.parent!;
      if (parent is RenderOffstage && parent.offstage) return false;
      final clip = parent.describeApproximatePaintClip(child);
      if (clip != null) {
        bounds = bounds.intersect(
            MatrixUtils.transformRect(parent.getTransformTo(null), clip));
        if (bounds.isEmpty) return false;
      }
      child = parent;
    }
    return true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final position in _positions) {
      position.removeListener(_scheduleCheck);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        _scheduleCheck();
        return false;
      },
      child: SizeChangedLayoutNotifier(
        child: TickerMode(
          enabled: _enabled,
          child: RepaintBoundary(key: _renderKey, child: widget.child),
        ),
      ),
    );
  }
}
