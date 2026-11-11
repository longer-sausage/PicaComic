import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/tools/download_runtime.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];
  final errors = <Object>[];
  late DownloadRuntime runtime;
  var expirations = 0;

  setUp(() {
    calls.clear();
    errors.clear();
    expirations = 0;
    runtime = DownloadRuntime(
      onExpired: () async => expirations++,
      onError: (error, _) => errors.add(error),
    );
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(DownloadRuntime.channel, (call) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(DownloadRuntime.channel, null);
    DownloadRuntime.channel.setMethodCallHandler(null);
  });

  test('rapid start, pause and resume preserve native call order', () async {
    final starting = Completer<void>();
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(DownloadRuntime.channel, (call) async {
      calls.add(call.method);
      if (calls.length == 1) await starting.future;
      return null;
    });
    final first = runtime.start(title: 'Downloading', content: '1 task');
    final pause = runtime.stop();
    final resume = runtime.start(title: 'Downloading', content: '1 task');
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['start']);
    starting.complete();
    await Future.wait([first, pause, resume]);
    expect(calls, ['start', 'stop', 'start']);
    expect(errors, isEmpty);
  });

  test('a refused foreground service does not poison later operations',
      () async {
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(DownloadRuntime.channel, (call) async {
      calls.add(call.method);
      if (calls.length == 1) {
        throw PlatformException(code: 'foreground_start_denied');
      }
      return null;
    });
    await runtime.start(title: 'Downloading', content: '1 task');
    await runtime.stop();
    await runtime.start(title: 'Downloading', content: '1 task');
    expect(calls, ['start', 'stop', 'start']);
    expect(errors.single, isA<PlatformException>());
  });

  test('an unavailable platform implementation still permits downloads',
      () async {
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(DownloadRuntime.channel, null);
    await runtime.start(title: 'Downloading', content: '1 task');
    await runtime.stop();
    expect(errors, everyElement(isA<MissingPluginException>()));
    expect(errors.length, 2);
  });

  test('expiration reserves a stop after persistence and before a new start',
      () async {
    final persisted = Completer<void>();
    await runtime.start(title: 'Downloading', content: '1 task');
    final expired = runtime.stop(after: persisted.future);
    final resumed = runtime.start(title: 'Downloading', content: '1 task');
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['start']);
    persisted.complete();
    await Future.wait([expired, resumed]);
    expect(calls, ['start', 'stop', 'start']);
  });

  test('platform expiration waits for the queue to be persisted', () async {
    final persisted = Completer<void>();
    runtime = DownloadRuntime(
      onExpired: () async {
        expirations++;
        await persisted.future;
      },
      onError: (error, _) => errors.add(error),
    );
    var acknowledged = false;
    final expired = binding.defaultBinaryMessenger.handlePlatformMessage(
      DownloadRuntime.channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('expired')),
      (_) => acknowledged = true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(expirations, 1);
    expect(acknowledged, isFalse);
    persisted.complete();
    await expired;
    expect(acknowledged, isTrue);
  });
}
