import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

/// Kept by image loaders when they translate a Dio error for the reader UI.
abstract interface class DownloadResponseError {
  int? get statusCode;
  Duration? get retryAfter;
}

extension DownloadCancellation on CancelToken {
  void throwIfCancelled() {
    final error = cancelError;
    if (error != null) throw error;
  }
}

Duration? downloadRetryAfter(Headers? headers) {
  final value = headers?.value('retry-after');
  if (value == null) return null;
  final seconds = int.tryParse(value);
  if (seconds != null) return Duration(seconds: max(0, seconds));
  try {
    final delay = HttpDate.parse(value).difference(DateTime.now().toUtc());
    return delay.isNegative ? Duration.zero : delay;
  } on FormatException {
    return null;
  } on HttpException {
    return null;
  }
}

/// Probes additional connections only while there is enough work to use them.
/// A probe must improve throughput; latency growth and congestion undo it.
class AdaptiveDownloadConcurrency {
  static const minConcurrency = 1;
  static const maxConcurrency = 16;
  static const initialConcurrency = 6;

  int _limit = initialConcurrency;
  int get limit => _limit;

  int _bytes = 0;
  int _successes = 0;
  int _failures = 0;
  int _responses = 0;
  int _responseMicros = 0;
  double? _throughput;
  double? _latency;
  int? _probeFrom;
  double? _probeThroughput;
  double? _probeLatency;
  int _cooldown = 0;
  int _idleSamples = 0;
  bool _backedOff = false;

  void recordBytes(int bytes) => _bytes += max(0, bytes);

  void recordResponse(Duration latency) {
    _responses++;
    _responseMicros += latency.inMicroseconds;
  }

  void recordSuccess() => _successes++;

  void recordFailure({bool congested = false}) {
    _failures++;
    if (congested && !_backedOff) _backOff();
  }

  void _backOff() {
    _limit = max(minConcurrency, _limit ~/ 2);
    _probeFrom = null;
    _throughput = null;
    _latency = null;
    _cooldown = 3;
    _backedOff = true;
  }

  void sample(Duration elapsed,
      {required int active,
      required bool hasPending,
      Duration oldestResponse = Duration.zero}) {
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds <= 0) return;
    final speed = _bytes / seconds;
    final latency = _responses == 0 ? null : _responseMicros / _responses;
    final failures = _failures;
    final successes = _successes;
    final backedOff = _backedOff;
    _bytes = _successes = _failures = _responses = _responseMicros = 0;
    _backedOff = false;

    if (backedOff) return;
    if (failures >= 2 && failures / max(1, successes + failures) >= 0.2) {
      _backOff();
      return;
    }
    // Tail pages and retry waits do not measure the capacity of the connection.
    if (!hasPending || active < _limit) return;
    if (_cooldown > 0) {
      _cooldown--;
      return;
    }
    if (speed <= 0) {
      _idleSamples++;
      if (_idleSamples >= 3 && oldestResponse >= const Duration(seconds: 6)) {
        _backOff();
        _idleSamples = 0;
      }
      return;
    }
    _idleSamples = 0;
    if (failures > 0) return;

    if (_probeFrom != null) {
      final useful = speed >= _probeThroughput! * 1.08;
      final slowResponse = latency != null &&
          _probeLatency != null &&
          latency > max(500000, _probeLatency! * 1.5);
      if (!useful || (slowResponse && speed < _probeThroughput! * 1.2)) {
        _limit = _probeFrom!;
        _cooldown = 3;
      }
      _probeFrom = null;
    } else if (_throughput != null &&
        speed < _throughput! * 0.75 &&
        latency != null &&
        _latency != null &&
        latency > max(500000, _latency! * 1.5)) {
      _limit = max(minConcurrency, (_limit * 0.75).floor());
      _cooldown = 2;
    } else if (_limit < maxConcurrency) {
      _probeFrom = _limit;
      _probeThroughput = speed;
      _probeLatency = latency ?? _latency;
      _limit = min(maxConcurrency, _limit + max(1, _limit ~/ 3));
    }
    _throughput =
        _throughput == null ? speed : _throughput! * 0.7 + speed * 0.3;
    if (latency != null) {
      _latency = _latency == null ? latency : _latency! * 0.7 + latency * 0.3;
    }
  }
}

class DownloadTaskContext {
  final CancelToken cancelToken = CancelToken();
  final AdaptiveDownloadConcurrency _controller;
  final void Function(int)? _onBytes;
  final _watch = Stopwatch()..start();
  bool _responded = false;

  DownloadTaskContext._(this._controller, this._onBytes);

  bool get isCanceled => cancelToken.isCancelled;

  /// Report network bytes only; image conversion and disk copies are excluded.
  void receivedBytes(int length) {
    if (isCanceled || length <= 0) return;
    if (!_responded) {
      _responded = true;
      _controller.recordResponse(_watch.elapsed);
    }
    _controller.recordBytes(length);
    _onBytes?.call(length);
  }
}

class _QueuedDownload<T> {
  final T value;
  int retries = 0;
  _QueuedDownload(this.value);
}

/// Work-conserving pool shared by page downloads and HTTP range downloads.
/// Retrying tasks wait outside the pool so one failed page cannot stall others.
class DownloadTaskScheduler<T> {
  final Future<void> Function(T, DownloadTaskContext) download;
  final void Function(T)? onComplete;
  final void Function(int)? onBytes;
  final bool Function() adaptive;
  final int Function() fixedConcurrency;
  final int maxRetries;
  final bool Function(Object)? shouldRetry;
  final _pending = Queue<_QueuedDownload<T>>();
  final _active = <DownloadTaskContext>{};
  final _executions = <Future<void>>{};
  final _retryTimers = <Timer>{};
  final _done = Completer<void>();
  final _watch = Stopwatch();
  final _random = Random();
  AdaptiveDownloadConcurrency _controller = AdaptiveDownloadConcurrency();
  Timer? _sampleTimer;
  Timer? _cooldownTimer;
  Duration _sampledAt = Duration.zero;
  Duration _blockedUntil = Duration.zero;
  bool _running = false;
  bool _stopped = false;
  late bool _wasAdaptive;

  DownloadTaskScheduler({
    required Iterable<T> tasks,
    required this.download,
    required this.adaptive,
    required this.fixedConcurrency,
    this.onComplete,
    this.onBytes,
    this.maxRetries = 4,
    this.shouldRetry,
    AdaptiveDownloadConcurrency? controller,
  }) {
    if (controller != null) _controller = controller;
    _pending.addAll(tasks.map(_QueuedDownload.new));
    _wasAdaptive = adaptive();
  }

  int get concurrency => adaptive()
      ? _controller.limit
      : fixedConcurrency().clamp(AdaptiveDownloadConcurrency.minConcurrency,
          AdaptiveDownloadConcurrency.maxConcurrency);

  int get activeCount => _active.length;
  AdaptiveDownloadConcurrency get controller => _controller;

  Future<void> get settled => Future.wait(_executions.toList());

  Future<void> run() {
    if (!_running && !_stopped) {
      _running = true;
      _watch.start();
      _sampleTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        refreshConcurrency();
        var oldest = Duration.zero;
        for (final task in _active) {
          if (!task._responded && task._watch.elapsed > oldest) {
            oldest = task._watch.elapsed;
          }
        }
        final now = _watch.elapsed;
        if (adaptive()) {
          _controller.sample(now - _sampledAt,
              active: _active.length,
              hasPending: _pending.isNotEmpty,
              oldestResponse: oldest);
        }
        _sampledAt = now;
        _pump();
      });
      _pump();
    }
    return _done.future;
  }

  /// New limits apply to new requests; in-flight transfers are allowed to drain.
  void refreshConcurrency() {
    if (_wasAdaptive != adaptive()) {
      _wasAdaptive = adaptive();
      _controller = AdaptiveDownloadConcurrency();
      _sampledAt = _watch.elapsed;
    }
    if (_running) _pump();
  }

  void _pump() {
    if (_stopped || !_running || _cooldownTimer != null) return;
    while (!_stopped &&
        _cooldownTimer == null &&
        _active.length < concurrency &&
        _pending.isNotEmpty) {
      final task = _pending.removeFirst();
      final context = DownloadTaskContext._(_controller, onBytes);
      _active.add(context);
      final execution = _execute(task, context);
      _executions.add(execution);
      unawaited(execution.then((_) => _executions.remove(execution)));
    }
    if (_active.isEmpty && _pending.isEmpty && _retryTimers.isEmpty) {
      _stop();
      _done.complete();
    }
  }

  Future<void> _execute(
      _QueuedDownload<T> task, DownloadTaskContext context) async {
    try {
      await download(task.value, context);
      if (_stopped || context.isCanceled) return;
      onComplete?.call(task.value);
      _controller.recordSuccess();
    } catch (error, stack) {
      if (_stopped || context.isCanceled) return;
      final status = switch (error) {
        DioException e => e.response?.statusCode,
        DownloadResponseError e => e.statusCode,
        _ => null,
      };
      final congested = status == 429 ||
          status == 503 ||
          (error is DioException &&
              (error.type == DioExceptionType.connectionTimeout ||
                  error.type == DioExceptionType.receiveTimeout));
      if (adaptive()) _controller.recordFailure(congested: congested);
      final permanentHttpError = status != null &&
          status >= 400 &&
          status < 500 &&
          status != 408 &&
          status != 429;
      if (task.retries >= maxRetries ||
          permanentHttpError ||
          (shouldRetry != null && !shouldRetry!(error))) {
        _stop();
        _done.completeError(error, stack);
        return;
      }
      task.retries++;
      final retryAfter = switch (error) {
        DioException e => downloadRetryAfter(e.response?.headers),
        DownloadResponseError e => e.retryAfter,
        _ => null,
      };
      final backoff = Duration(
          milliseconds: (1000 << (task.retries - 1)) + _random.nextInt(250));
      final delay =
          retryAfter != null && retryAfter > backoff ? retryAfter : backoff;
      if (status == 429 || status == 503) _coolDown(delay);
      late final Timer timer;
      timer = Timer(delay, () {
        _retryTimers.remove(timer);
        _pending.addFirst(task);
        _pump();
      });
      _retryTimers.add(timer);
    } finally {
      _active.remove(context);
      _pump();
    }
  }

  void _coolDown(Duration delay) {
    final until = _watch.elapsed + delay;
    if (_cooldownTimer != null && until <= _blockedUntil) return;
    _blockedUntil = until;
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer(delay, () {
      _cooldownTimer = null;
      _pump();
    });
  }

  void _stop() {
    _stopped = true;
    _sampleTimer?.cancel();
    _cooldownTimer?.cancel();
    for (final timer in _retryTimers) {
      timer.cancel();
    }
    _retryTimers.clear();
    for (final task in _active) {
      task.cancelToken.cancel('Download stopped');
    }
    _watch.stop();
  }

  void cancel() {
    if (_stopped) return;
    _stop();
    _done.complete();
  }
}
