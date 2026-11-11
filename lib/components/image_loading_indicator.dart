import 'package:flutter/material.dart';

/// Stay visibly busy while connecting, waiting for bytes, or decoding.
class ImageLoadingIndicator extends StatelessWidget {
  const ImageLoadingIndicator({super.key, this.progress, this.size = 24});

  final ImageChunkEvent? progress;
  final double size;

  @override
  Widget build(BuildContext context) {
    final loaded = progress?.cumulativeBytesLoaded ?? 0;
    final total = progress?.expectedTotalBytes;
    final value = total != null && total > 0 && loaded > 0 && loaded < total
        ? loaded / total
        : null;
    return Center(
      child: SizedBox.square(
        dimension: size,
        child: CircularProgressIndicator(
          strokeWidth: 3,
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
          value: value,
        ),
      ),
    );
  }
}
