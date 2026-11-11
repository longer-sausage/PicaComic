// Synthetic loopback comparison of fixed six-way and adaptive scheduling.
// Run with: dart run tool/benchmark_downloads.dart
// This models per-request latency, not a real source's bandwidth or rate limit.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:pica_comic/network/download_scheduler.dart';

Future<void> main() async {
  const count = 600;
  final bytes = Uint8List(64 * 1024);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final response = request.response;
    response.contentLength = bytes.length * 4;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    for (var i = 0; i < 4; i++) {
      response.add(bytes);
      await response.flush();
      if (i < 3) await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await response.close();
  });
  Future<Map<String, Object>> run(bool adaptive) async {
    final client = HttpClient()..maxConnectionsPerHost = 16;
    final watch = Stopwatch()..start();
    var peak = 0;
    var received = 0;
    late final DownloadTaskScheduler<int> scheduler;
    scheduler = DownloadTaskScheduler<int>(
      tasks: Iterable.generate(count),
      adaptive: () => adaptive,
      fixedConcurrency: () => 6,
      download: (_, context) async {
        if (scheduler.concurrency > peak) peak = scheduler.concurrency;
        final request = await client
            .getUrl(Uri.parse('http://127.0.0.1:${server.port}/image'));
        final response = await request.close();
        await for (final chunk in response) {
          received += chunk.length;
          context.receivedBytes(chunk.length);
        }
      },
    );
    try {
      await scheduler.run();
    } finally {
      watch.stop();
      client.close(force: true);
    }
    return {
      'mode': adaptive ? 'adaptive' : 'fixed6',
      'elapsedMs': watch.elapsedMilliseconds,
      'bytes': received,
      'peakConcurrency': peak,
      'requests': count
    };
  }

  try {
    stdout.writeln(jsonEncode(await run(false)));
    stdout.writeln(jsonEncode(await run(true)));
  } finally {
    await server.close(force: true);
  }
}
