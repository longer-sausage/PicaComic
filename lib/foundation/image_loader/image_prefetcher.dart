import 'base_image_provider.dart';

/// Prefetch encoded bytes without decoding offscreen animation frames.
class ImagePrefetcher {
  ImagePrefetcher({this.maximumConcurrentLoads = 2});

  final int maximumConcurrentLoads;
  final _pending = <Object, BaseImageProvider>{};
  final _loading = <Object>{};
  bool _disposed = false;

  void prefetch(Iterable<BaseImageProvider> providers) {
    if (_disposed) return;
    // Replace stale queued work when the reader jumps to another position.
    final next = <Object, BaseImageProvider>{};
    for (final provider in providers) {
      if (!provider.isByteCached && !_loading.contains(provider)) {
        next[provider] = provider;
      }
    }
    _pending
      ..clear()
      ..addAll(next);
    _drain();
  }

  void _drain() {
    while (!_disposed &&
        _loading.length < maximumConcurrentLoads &&
        _pending.isNotEmpty) {
      final key = _pending.keys.first;
      final provider = _pending.remove(key)!;
      _loading.add(key);
      _load(key, provider);
    }
  }

  Future<void> _load(Object key, BaseImageProvider provider) async {
    try {
      await provider.loadBytes();
    } catch (_) {
      // Displaying the image will report the error and can retry the request.
    } finally {
      _loading.remove(key);
      _drain();
    }
  }

  void clear() => _pending.clear();

  void dispose() {
    _disposed = true;
    clear();
  }
}
