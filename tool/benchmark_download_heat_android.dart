// Build ONLY in an isolated checkout with an applicationId suffix:
// flutter build apk --release --no-pub -t tool/benchmark_download_heat_android.dart
//   --target-platform android-x64 --dart-define=BENCH_CONCURRENCY=16
// Results are written to logcat. This app downloads generated loopback data.
import 'dart:convert';

import 'package:flutter/material.dart';

import 'download_heat_workload.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
      home: Scaffold(
          body: Center(
              child: Text('Download resource benchmark — local data only')))));
  _run();
}

Future<void> _run() async {
  try {
    final result = await runDownloadHeatBenchmark();
    // ignore: avoid_print
    print('DOWNLOAD_HEAT_BENCHMARK ${jsonEncode(result)}');
  } catch (error, stack) {
    // ignore: avoid_print
    print('DOWNLOAD_HEAT_BENCHMARK_FAILED $error\n$stack');
  }
}
