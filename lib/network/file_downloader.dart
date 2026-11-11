import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pica_comic/network/download_scheduler.dart';
import 'package:pica_comic/network/http_client.dart';

class FileDownloader {
  final String url;
  final String savePath;
  final String? proxy;
  int maxConcurrent;
  bool adaptive;

  FileDownloader(this.url, this.savePath, this.proxy,
      {this.maxConcurrent = 6, this.adaptive = true});

  static const _chunkSize = 4 * 1024 * 1024;
  static const _writeBufferSize = 256 * 1024;
  final _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {'Accept-Encoding': 'identity'}));
  final _requestToken = CancelToken();
  final _finished = Completer<void>();
  final _blocks = <_DownloadBlock>[];
  DownloadTaskScheduler<_DownloadBlock>? _scheduler;
  RandomAccessFile? _file;
  Future<void> _writes = Future.value();
  Future<void> _statusWrites = Future.value();
  Timer? _statusTimer;
  Timer? _speedTimer;
  StreamController<DownloadingStatus>? _stream;
  bool _canceled = false;
  bool _dirty = false;
  bool _sequential = false;
  int _fileSize = 0;
  int _currentBytes = 0;
  int _networkBytes = 0;
  int _lastNetworkBytes = 0;
  final _speedWatch = Stopwatch();

  int get concurrency => _sequential
      ? 1
      : _scheduler?.concurrency ??
          (adaptive
              ? AdaptiveDownloadConcurrency.initialConcurrency
              : maxConcurrent);

  void updateConcurrency({required bool adaptive, required int maxConcurrent}) {
    this.adaptive = adaptive;
    this.maxConcurrent = maxConcurrent;
    _scheduler?.refreshConcurrency();
  }

  File get _statusFile => File('$savePath.download');

  Future<void> _writeStatus({bool flush = false}) {
    if (!_dirty && !flush) return _statusWrites;
    _dirty = false;
    final snapshot = _blocks.map((block) => block.toString()).join('\n');
    // Snapshots contain committed bytes only. Serialize the much less frequent
    // checkpoint writes independently of the data file's write queue.
    return _statusWrites = _statusWrites.then((_) async {
      if (flush) await _file?.flush();
      final temporary = File('$savePath.download.tmp');
      await temporary.writeAsString(snapshot, flush: flush);
      await temporary.rename(_statusFile.path);
    });
  }

  Future<void> _prepareFile() async {
    final file = File(savePath);
    await file.parent.create(recursive: true);
    var resume = false;
    if (await file.exists() &&
        await _statusFile.exists() &&
        await file.length() == _fileSize) {
      try {
        final saved = (await _statusFile.readAsLines())
            .map(_DownloadBlock.fromString)
            .toList();
        var position = 0;
        for (final block in saved) {
          if (block.start != position ||
              block.end <= block.start ||
              block.end > _fileSize ||
              block.downloadedBytes < 0 ||
              block.downloadedBytes > block.end - block.start) {
            throw const FormatException('Invalid download checkpoint');
          }
          position = block.end;
        }
        if (position == _fileSize) {
          _blocks.addAll(saved);
          resume = true;
        }
      } on FormatException {
        // A partial or outdated checkpoint must never create overlapping ranges.
      }
    }
    if (!resume) {
      for (var start = 0; start < _fileSize; start += _chunkSize) {
        _blocks
            .add(_DownloadBlock(start, min(start + _chunkSize, _fileSize), 0));
      }
    }
    _currentBytes =
        _blocks.fold(0, (sum, block) => sum + block.downloadedBytes);
    _file = await file.open(mode: resume ? FileMode.append : FileMode.write);
    await _file!.truncate(_fileSize);
    _dirty = true;
    await _writeStatus(flush: true);
  }

  Stream<DownloadingStatus> start() {
    if (_stream != null) throw StateError('Download already started');
    setProxy(proxy);
    final stream = _stream = StreamController<DownloadingStatus>(
      onListen: () => unawaited(_download()),
      onCancel: stop,
    );
    return stream.stream;
  }

  void _report({int speed = 0, bool finished = false}) {
    if (_canceled) return;
    _stream!.add(DownloadingStatus(
        _currentBytes, _fileSize, speed, finished, concurrency));
  }

  Future<void> _download() async {
    Object? failure;
    StackTrace? failureStack;
    try {
      if (_canceled) return;
      _speedWatch.start();
      _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final elapsed = _speedWatch.elapsedMicroseconds;
        final speed = elapsed == 0
            ? 0
            : ((_networkBytes - _lastNetworkBytes) * 1000000 / elapsed).round();
        _lastNetworkBytes = _networkBytes;
        _speedWatch.reset();
        _report(speed: speed);
      });
      final head = await _dio.head<void>(url,
          cancelToken: _requestToken,
          options: Options(
              validateStatus: (status) =>
                  status != null &&
                  (status < 400 || status == 405 || status == 501)));
      if (_canceled) return;
      _fileSize = int.tryParse(head.headers.value('content-length') ?? '') ?? 0;
      final ranges =
          head.headers.value('accept-ranges')?.toLowerCase() == 'bytes';
      if (ranges && _fileSize > 0) {
        await _prepareFile();
        if (_canceled) return;
        _statusTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
          unawaited(_writeStatus().catchError((Object error, StackTrace stack) {
            _requestToken.cancel(error);
            _scheduler?.cancel();
          }));
        });
        final scheduler = _scheduler = DownloadTaskScheduler<_DownloadBlock>(
          tasks: _blocks.where((block) => !block.finished),
          adaptive: () => adaptive,
          fixedConcurrency: () => maxConcurrent,
          download: _fetchBlock,
          shouldRetry: (error) => error is! _InvalidRangeResponse,
          onBytes: (length) => _networkBytes += length,
        );
        _report();
        try {
          await scheduler.run();
        } on _InvalidRangeResponse {
          // Abort all old writers before falling back from ignored HTTP ranges.
          await scheduler.settled;
          _statusTimer?.cancel();
          await _writes;
          await _statusWrites;
          await _downloadWholeFile();
        } finally {
          await scheduler.settled;
        }
      } else {
        await _downloadWholeFile();
      }
      if (_canceled) return;
      if (_currentBytes != _fileSize) {
        throw FileSystemException(
            'Expected $_fileSize bytes, got $_currentBytes');
      }
      _statusTimer?.cancel();
      await _writes;
      await _statusWrites;
      await _file?.flush();
      if (await _statusFile.exists()) await _statusFile.delete();
      _report(finished: true);
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      _speedTimer?.cancel();
      _statusTimer?.cancel();
      _scheduler?.cancel();
      await _scheduler?.settled;
      try {
        await _writes;
        await _statusWrites;
        if (!_sequential && _file != null && (_canceled || failure != null)) {
          await _writeStatus(flush: true);
        }
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      } finally {
        try {
          await _file?.close();
        } catch (error, stack) {
          failure ??= error;
          failureStack ??= stack;
        } finally {
          _file = null;
          _dio.close(force: true);
          if (failure != null && !_canceled) {
            _stream!.addError(failure, failureStack);
          }
          if (!_finished.isCompleted) _finished.complete();
          unawaited(_stream!.close());
        }
      }
    }
  }

  Future<void> _writeBlock(
      _DownloadBlock block, Uint8List bytes, DownloadTaskContext context) {
    final writing = _writes.then((_) async {
      context.cancelToken.throwIfCancelled();
      await _file!.setPosition(block.start + block.downloadedBytes);
      await _file!.writeFrom(bytes);
      block.downloadedBytes += bytes.length;
      _currentBytes += bytes.length;
      _dirty = true;
    });
    // A failed request must not poison the shared writer for other ranges.
    _writes = writing.catchError((Object _) {});
    return writing;
  }

  Future<void> _fetchBlock(
      _DownloadBlock block, DownloadTaskContext context) async {
    final start = block.start + block.downloadedBytes;
    final response = await _dio.get<ResponseBody>(url,
        cancelToken: context.cancelToken,
        options: Options(
            responseType: ResponseType.stream,
            headers: {'Range': 'bytes=$start-${block.end - 1}'}));
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
        .firstMatch(response.headers.value('content-range') ?? '');
    if (response.statusCode != 206 ||
        match == null ||
        int.parse(match[1]!) != start ||
        int.parse(match[2]!) != block.end - 1 ||
        int.parse(match[3]!) != _fileSize) {
      await response.data!.stream.listen(null).cancel();
      throw const _InvalidRangeResponse();
    }
    final buffer = BytesBuilder(copy: false);
    var received = 0;
    await for (final bytes in response.data!.stream) {
      context.cancelToken.throwIfCancelled();
      received += bytes.length;
      if (start + received > block.end) throw const _InvalidRangeResponse();
      context.receivedBytes(bytes.length);
      buffer.add(bytes);
      if (buffer.length >= _writeBufferSize) {
        await _writeBlock(block, buffer.takeBytes(), context);
      }
    }
    if (buffer.isNotEmpty) {
      await _writeBlock(block, buffer.takeBytes(), context);
    }
    if (!block.finished) throw const HttpException('Incomplete download range');
  }

  Future<void> _downloadWholeFile() async {
    _sequential = true;
    _currentBytes = 0;
    await _file?.close();
    _file = null;
    if (await _statusFile.exists()) await _statusFile.delete();
    final file = File(savePath);
    await file.parent.create(recursive: true);
    _file = await file.open(mode: FileMode.write);
    final response = await _dio.get<ResponseBody>(url,
        cancelToken: _requestToken,
        options: Options(responseType: ResponseType.stream));
    _fileSize = max(0, response.data!.contentLength);
    await for (final bytes in response.data!.stream) {
      _requestToken.throwIfCancelled();
      _networkBytes += bytes.length;
      await _file!.writeFrom(bytes);
      _currentBytes += bytes.length;
    }
    if (_fileSize == 0) _fileSize = _currentBytes;
  }

  Future<void> stop() async {
    if (_canceled) return _finished.future;
    _canceled = true;
    _requestToken.cancel('Download stopped');
    _scheduler?.cancel();
    if (_stream == null) return;
    await _finished.future;
  }
}

class _DownloadBlock {
  final int start;
  final int end;
  int downloadedBytes;
  bool get finished => downloadedBytes == end - start;

  _DownloadBlock(this.start, this.end, this.downloadedBytes);

  factory _DownloadBlock.fromString(String value) {
    final parts = value.split('-');
    if (parts.length != 3) {
      throw const FormatException('Invalid download block');
    }
    return _DownloadBlock(
        int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }

  @override
  String toString() => '$start-$end-$downloadedBytes';
}

class _InvalidRangeResponse implements Exception {
  const _InvalidRangeResponse();
  @override
  String toString() => 'Server returned an invalid HTTP range';
}

class DownloadingStatus {
  final int downloadedBytes;
  final int totalBytes;
  final bool isFinished;
  final int bytesPerSecond;
  final int concurrency;

  const DownloadingStatus(
      this.downloadedBytes, this.totalBytes, this.bytesPerSecond,
      [this.isFinished = false, this.concurrency = 1]);

  @override
  String toString() => 'Downloaded: $downloadedBytes/$totalBytes '
      '${isFinished ? "Finished" : ""}';
}
