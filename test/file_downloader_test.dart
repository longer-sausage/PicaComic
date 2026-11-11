import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/file_downloader.dart';

void main() {
  late HttpServer server;
  late Directory directory;
  late Uint8List content;
  late String url;
  late String destination;
  var active = 0;
  var peak = 0;
  var delay = Duration.zero;
  var advertiseRanges = true;
  var ignoreRanges = false;
  var headUnsupported = false;
  var chunked = false;
  var transientFailure = false;
  final ranges = <String?>[];

  Future<void> serve(HttpRequest request) async {
    final response = request.response;
    if (advertiseRanges) response.headers.set('accept-ranges', 'bytes');
    if (request.method == 'HEAD') {
      response.statusCode = headUnsupported ? 405 : 200;
      response.contentLength = headUnsupported ? 0 : content.length;
      await response.close();
      return;
    }
    final range = request.headers.value('range');
    ranges.add(range);
    if (transientFailure) {
      transientFailure = false;
      response.statusCode = 503;
      response.headers.set('retry-after', '0');
      await response.close();
      return;
    }
    var start = 0;
    var end = content.length;
    if (range != null && !ignoreRanges) {
      final bounds = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
      start = int.parse(bounds[1]!);
      end = int.parse(bounds[2]!) + 1;
      response.statusCode = 206;
      response.headers
          .set('content-range', 'bytes $start-${end - 1}/${content.length}');
    }
    if (!chunked) response.contentLength = end - start;
    active++;
    if (active > peak) peak = active;
    try {
      for (var offset = start; offset < end; offset += 64 * 1024) {
        final limit = (offset + 64 * 1024).clamp(0, end);
        response.add(Uint8List.sublistView(content, offset, limit));
        await response.flush();
        if (delay > Duration.zero) await Future<void>.delayed(delay);
      }
      await response.close();
    } on SocketException {
      // Pausing the downloader deliberately closes these sockets.
    } on HttpException {
      // Canceled range requests may be cut short at any byte boundary.
    } finally {
      active--;
    }
  }

  Future<void> verifyFile() async {
    final downloaded = await File(destination).readAsBytes();
    expect(downloaded.length, content.length);
    expect(md5.convert(downloaded), md5.convert(content));
    expect(File('$destination.download').existsSync(), isFalse);
  }

  setUp(() async {
    active = peak = 0;
    delay = Duration.zero;
    advertiseRanges = true;
    ignoreRanges = headUnsupported = chunked = transientFailure = false;
    ranges.clear();
    directory = await Directory.systemTemp.createTemp('pica-range-pool-');
    destination = '${directory.path}/file.bin';
    content = Uint8List.fromList(List.generate(
        9 * 1024 * 1024 + 123, (index) => (index * 31 + index ~/ 65536) % 251));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${server.port}/file.bin';
    server.listen((request) => unawaited(serve(request)));
  });

  tearDown(() async {
    await server.close(force: true);
    expect(
        directory.absolute.path.startsWith(Directory.systemTemp.absolute.path),
        isTrue);
    expect(directory.uri.pathSegments.where((s) => s.isNotEmpty).last,
        startsWith('pica-range-pool-'));
    await directory.delete(recursive: true);
  });

  test('range workers share a buffered writer without corrupting the file',
      () async {
    delay = const Duration(milliseconds: 1);
    final statuses = await FileDownloader(url, destination, null,
            adaptive: false, maxConcurrent: 2)
        .start()
        .toList();
    await verifyFile();
    expect(peak, 2);
    expect(ranges, hasLength(3));
    expect(statuses.last.isFinished, isTrue);
    expect(statuses.last.concurrency, 2);
  });

  test('automatic mode is enabled by default for archive downloads', () async {
    final downloader = FileDownloader(url, destination, null);
    expect(downloader.adaptive, isTrue);
    expect(downloader.concurrency, 6);
    await downloader.start().drain<void>();
    await verifyFile();
  });

  test(
      'pause checkpoints committed bytes and resume requests only missing ranges',
      () async {
    delay = const Duration(milliseconds: 20);
    final downloader = FileDownloader(url, destination, null,
        adaptive: false, maxConcurrent: 2);
    final progress = Completer<void>();
    final ended = Completer<void>();
    downloader.start().listen((status) {
      if (status.downloadedBytes > 0 && !progress.isCompleted) {
        progress.complete();
      }
    }, onError: ended.completeError, onDone: ended.complete);
    await progress.future.timeout(const Duration(seconds: 5));
    await downloader.stop();
    await ended.future;
    final checkpoint = await File('$destination.download').readAsLines();
    final committed = checkpoint.fold<int>(
        0, (sum, line) => sum + int.parse(line.split('-')[2]));
    expect(committed, greaterThan(0));
    expect(committed, lessThan(content.length));
    ranges.clear();
    delay = Duration.zero;
    await FileDownloader(url, destination, null,
            adaptive: false, maxConcurrent: 2)
        .start()
        .drain<void>();
    expect(
        ranges.any((range) => range?.startsWith('bytes=0-') ?? false), isFalse);
    await verifyFile();
  });

  test('ignored ranges abort the pool and fall back to a complete single GET',
      () async {
    ignoreRanges = true;
    await FileDownloader(url, destination, null).start().drain<void>();
    expect(ranges.last, isNull);
    await verifyFile();
  });

  test('HEAD refusal and unknown content length support sequential streaming',
      () async {
    headUnsupported = chunked = true;
    advertiseRanges = false;
    final statuses =
        await FileDownloader(url, destination, null).start().toList();
    expect(ranges, [null]);
    expect(statuses.last.totalBytes, content.length);
    expect(statuses.last.concurrency, 1);
    await verifyFile();
  });

  test(
      'invalid checkpoints restart safely and transient errors retry their range',
      () async {
    await File(destination).writeAsBytes(content);
    await File('$destination.download').writeAsString('0-1024-500\n500-2048-1');
    transientFailure = true;
    await FileDownloader(url, destination, null,
            adaptive: false, maxConcurrent: 2)
        .start()
        .drain<void>();
    expect(ranges.where((range) => range?.startsWith('bytes=0-') ?? false),
        hasLength(2));
    await verifyFile();
  });
}
