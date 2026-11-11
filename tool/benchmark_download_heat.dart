// Run with flutter test --no-pub tool/benchmark_download_heat.dart
//   --dart-define=BENCH_CONCURRENCY=6 (or 16).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'download_heat_workload.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('parallel image download resource benchmark', () async {
    // Use real HTTP instead of Flutter tests' synthetic HTTP 400 responses.
    HttpOverrides.global = null;
    final result = await runDownloadHeatBenchmark();
    // ignore: avoid_print
    print('DOWNLOAD_HEAT_BENCHMARK ${jsonEncode(result)}');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
