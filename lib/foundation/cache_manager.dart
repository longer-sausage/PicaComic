import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/tools/io_extensions.dart';
import 'package:sqlite3/sqlite3.dart';

class CacheManager {
  static String get cachePath => '${App.cachePath}/cache';

  static CacheManager? instance;

  late Database _db;

  int? _currentSize;
  late final Future<void> _ready;
  Future<void> _mutations = Future.value();
  int _entryCount = 0;
  final _maintenanceWatch = Stopwatch()..start();
  Duration? _lastExpiryCheck;

  /// size in bytes
  int get currentSize => _currentSize ?? 0;

  int dir = 0;

  int _limitSize = 2 * 1024 * 1024 * 1024;

  int get limitSize => _limitSize;

  CacheManager._create() {
    Directory(cachePath).createSync(recursive: true);
    _db = sqlite3.open('${App.dataPath}/cache.db');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS cache (
        key TEXT PRIMARY KEY NOT NULL,
        dir TEXT NOT NULL,
        name TEXT NOT NULL,
        expires INTEGER NOT NULL,
        type TEXT
      )
    ''');
    // 旧版本的表中没有type字段，需要添加
    try {
      _db.execute('''
        ALTER TABLE cache ADD COLUMN type TEXT
      ''');
    } catch (e) {
      // ignore
    }
    _entryCount = _db.select('SELECT COUNT(*) FROM cache').first[0] as int;
    // Scan once at startup, before allowing cache mutations. Page completions
    // account for their own bytes instead of spawning a directory scan each.
    _ready = compute((path) => Directory(path).size, cachePath).then((value) {
      _currentSize = value;
    });
  }

  factory CacheManager() => instance ??= CacheManager._create();

  /// set cache size limit in MB
  void setLimitSize(int size) {
    _limitSize = size * 1024 * 1024;
  }

  void setType(String key, String? type) {
    _db.execute('''
      UPDATE cache
      SET type = ?
      WHERE key = ?
    ''', [type, key]);
  }

  String? getType(String key) {
    var res = _db.select('''
      SELECT type FROM cache
      WHERE key = ?
    ''', [key]);
    if (res.isEmpty) {
      return null;
    }
    return res.first[0];
  }

  Future<void> writeCache(String key, Uint8List data,
      [int duration = 7 * 24 * 60 * 60 * 1000]) async {
    final caching = await openWrite(key);
    try {
      await caching.writeBytes(data);
      await caching.close(duration: duration);
    } catch (_) {
      await caching.cancel();
      rethrow;
    }
  }

  Future<CachingFile> openWrite(String key) async {
    await _ready;
    this.dir++;
    this.dir %= 100;
    var dir = this.dir;
    var name = md5.convert(Uint8List.fromList(key.codeUnits)).toString();
    var file = File('$cachePath/$dir/$name');
    while (await file.exists()) {
      name = md5.convert(Uint8List.fromList(name.codeUnits)).toString();
      file = File('$cachePath/$dir/$name');
    }
    await file.create(recursive: true);
    return CachingFile._(this, key, dir.toString(), name, file);
  }

  Future<String?> findCache(String key) async {
    var res = _db.select('''
      SELECT * FROM cache
      WHERE key = ?
    ''', [key]);
    if (res.isEmpty) {
      return null;
    }
    var row = res.first;
    var dir = row[1] as String;
    var name = row[2] as String;
    var file = File('$cachePath/$dir/$name');
    if (await file.exists()) {
      return file.path;
    }
    return null;
  }

  // Only metadata/accounting and eviction are serialized; network transfers
  // and buffered data writes remain parallel. Recover the queue after errors.
  Future<void> _mutate(Future<void> Function() action) {
    final result = _mutations.then((_) async {
      await _ready;
      await action();
    });
    _mutations = result.catchError((Object _) {});
    return result;
  }

  Future<void> _removeRow(Row row) async {
    final file = File('$cachePath/${row['dir']}/${row['name']}');
    if (await file.exists()) {
      final size = await file.length();
      await file.delete();
      _currentSize = (_currentSize! - size).clamp(0, _currentSize!);
    }
    _db.execute('DELETE FROM cache WHERE key = ?', [row['key']]);
    _entryCount--;
  }

  Future<void> _commit(CachingFile caching, int duration) => _mutate(() async {
        final size = await caching.file.length();
        final previous =
            _db.select('SELECT * FROM cache WHERE key = ?', [caching.key]);
        for (final row in previous) {
          await _removeRow(row);
        }
        _db.execute('''
      INSERT INTO cache (key, dir, name, expires) VALUES (?, ?, ?, ?)
    ''', [
          caching.key,
          caching.dir,
          caching.name,
          DateTime.now().millisecondsSinceEpoch + duration
        ]);
        _currentSize = _currentSize! + size;
        _entryCount++;
        await _checkCache();
      });

  Future<void> _discard(CachingFile caching) => _mutate(() async {
        final rows =
            _db.select('SELECT * FROM cache WHERE key = ?', [caching.key]);
        for (final row in rows) {
          if (row['dir'] == caching.dir && row['name'] == caching.name) {
            await _removeRow(row);
            return;
          }
        }
        await caching.file.deleteIgnoreError();
      });

  Future<void> checkCache() => _mutate(() => _checkCache(force: true));

  Future<void> _checkCache({bool force = false}) async {
    final now = _maintenanceWatch.elapsed;
    if (force ||
        _lastExpiryCheck == null ||
        now - _lastExpiryCheck! >= const Duration(minutes: 1)) {
      for (final row in _db.select('SELECT * FROM cache WHERE expires < ?',
          [DateTime.now().millisecondsSinceEpoch])) {
        await _removeRow(row);
      }
      _lastExpiryCheck = now;
    }
    // Enforce both limits even between expiry checks. Always make progress if
    // files are missing; an orphan-only directory must not spin forever.
    while (_currentSize! > _limitSize || _entryCount > 2000) {
      final rows =
          _db.select('SELECT * FROM cache ORDER BY expires ASC LIMIT 32');
      if (rows.isEmpty) break;
      for (final row in rows) {
        if (_currentSize! <= _limitSize && _entryCount <= 2000) break;
        await _removeRow(row);
      }
    }
  }

  Future<void> delete(String key) => _mutate(() async {
        for (final row
            in _db.select('SELECT * FROM cache WHERE key = ?', [key])) {
          await _removeRow(row);
        }
      });

  Future<void> clear() => _mutate(() async {
        await Directory(cachePath).delete(recursive: true);
        await Directory(cachePath).create(recursive: true);
        _db.execute('DELETE FROM cache');
        _currentSize = 0;
        _entryCount = 0;
        _lastExpiryCheck = null;
      });

  Future<void> deleteKeyword(String keyword) => _mutate(() async {
        for (final row in _db
            .select('SELECT * FROM cache WHERE key LIKE ?', ['%$keyword%'])) {
          await _removeRow(row);
        }
      });

  Future<void> dispose() async {
    await _ready;
    await _mutations;
    _db.dispose();
    if (identical(instance, this)) instance = null;
  }
}

class CachingFile {
  CachingFile._(this._manager, this.key, this.dir, this.name, this.file);

  final CacheManager _manager;

  final String key;

  final String dir;

  final String name;

  final File file;

  final _buffer = BytesBuilder(copy: false);
  Future<void>? _closed;

  Future<void> writeBytes(List<int> data) async {
    _buffer.add(data);
    if (_buffer.length > 1024 * 1024) {
      await file.writeAsBytes(_buffer.takeBytes(), mode: FileMode.append);
    }
  }

  Future<void> close({int duration = 7 * 24 * 60 * 60 * 1000}) =>
      _closed ??= _close(duration);

  Future<void> _close(int duration) async {
    if (_buffer.isNotEmpty) {
      await file.writeAsBytes(_buffer.takeBytes(), mode: FileMode.append);
    }
    await _manager._commit(this, duration);
  }

  Future<void> cancel() async {
    _buffer.clear();
    await _manager._discard(this);
  }

  void reset() {
    _buffer.clear();
    if (file.existsSync()) {
      file.deleteSync();
    }
  }
}
