import 'dart:typed_data';

/// Shares encoded data between display sizes and prefetch requests.
class ImageBytesCache {
  ImageBytesCache({required int maximumSizeBytes})
      : _maximumSizeBytes = maximumSizeBytes;

  final _entries = <Object, Uint8List>{};
  final _pending = <Object, Future<Uint8List>>{};
  int _maximumSizeBytes;
  int _sizeBytes = 0;
  int _generation = 0;

  int get sizeBytes => _sizeBytes;

  bool containsKey(Object key) => _entries.containsKey(key);

  set maximumSizeBytes(int value) {
    assert(value >= 0);
    _maximumSizeBytes = value;
    _trim();
  }

  Future<Uint8List> load(Object key, Future<Uint8List> Function() loader) {
    final cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached;
      return Future.value(cached);
    }
    return _pending[key] ??= _load(key, loader);
  }

  Future<Uint8List> _load(
      Object key, Future<Uint8List> Function() loader) async {
    final generation = _generation;
    // Establish the pending entry before invoking a possibly synchronous loader.
    await Future<void>.value();
    try {
      final data = await loader();
      if (generation == _generation && data.length <= _maximumSizeBytes) {
        evict(key);
        _entries[key] = data;
        _sizeBytes += data.length;
        _trim();
      }
      return data;
    } finally {
      if (generation == _generation) _pending.remove(key);
    }
  }

  void evict(Object key) {
    final data = _entries.remove(key);
    if (data != null) _sizeBytes -= data.length;
  }

  void _trim() {
    while (_sizeBytes > _maximumSizeBytes && _entries.isNotEmpty) {
      evict(_entries.keys.first);
    }
  }

  void clear() {
    _generation++;
    _entries.clear();
    _pending.clear();
    _sizeBytes = 0;
  }
}
