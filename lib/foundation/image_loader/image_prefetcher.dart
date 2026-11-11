import 'base_image_provider.dart';

/// Prefetch encoded bytes without decoding offscreen animation frames.
class ImagePrefetcher {
  ImagePrefetcher({this.maximumConcurrentLoads = 2})
      : assert(maximumConcurrentLoads > 0);

  final int maximumConcurrentLoads;
  final _pending = <Object, BaseImageProvider>{};
  final _loading = <Object>{};
  final _priority = <Object>{};
  final _pendingPriority = <Object, BaseImageProvider>{};
  late int _concurrency = maximumConcurrentLoads;
  bool _waitForPriority = true;
  bool _disposed = false;

  void prefetch(Iterable<BaseImageProvider> providers,
      {Iterable<BaseImageProvider> priority = const [],
      int? concurrency,
      bool waitForPriority = true}) {
    if (_disposed) return;
    assert(concurrency == null || concurrency > 0);
    _concurrency = concurrency ?? maximumConcurrentLoads;
    _waitForPriority = waitForPriority;
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
    _priority.clear();
    _pendingPriority.clear();
    for (final provider in priority) {
      _pending.remove(provider);
      if (provider.isByteCached) continue;
      _priority.add(provider);
      if (!_loading.contains(provider)) _pendingPriority[provider] = provider;
    }
    _drain();
  }

  void _drain() {
    // Reserve two slots for visible pages after a jump. Continuous reading
    // keeps the remaining slots busy even when a visible request is slow.
    while (!_disposed &&
        _loading.length < _concurrency + 2 &&
        _pendingPriority.isNotEmpty) {
      final key = _pendingPriority.keys.first;
      final provider = _pendingPriority.remove(key)!;
      _loading.add(key);
      _load(key, provider);
    }
    if (_waitForPriority && _priority.isNotEmpty) return;
    while (
        !_disposed && _loading.length < _concurrency && _pending.isNotEmpty) {
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
      _priority.remove(key);
      _drain();
    }
  }

  void clear() {
    _pending.clear();
    _priority.clear();
    _pendingPriority.clear();
  }

  void dispose() {
    _disposed = true;
    clear();
  }
}
