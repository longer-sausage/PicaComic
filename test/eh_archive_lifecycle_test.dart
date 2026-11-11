import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/network/eh_network/eh_download_model.dart';
import 'package:pica_comic/tools/translations.dart';

class _ArchiveDownload extends EhDownloadingItem {
  final String folder;

  _ArchiveDownload(
      this.folder, String url, void Function() updated, void Function() error)
      : super.fromMap({
          'id': 'archive-test',
          'type': 1,
          '_downloadedNum': 0,
          '_downloadingEp': 0,
          'index': 0,
          'directory': 'archive-test',
          'links': null,
          'gallery': {
            'title': 'Archive',
            'type': 'Manga',
            'time': '',
            'uploader': '',
            'stars': 0.0,
            'coverPath': '',
            'tags': <String, dynamic>{},
            'favorite': false,
            'link': 'https://e-hentai.org/g/1/test/',
            'maxPage': '1',
            'auth': {'archiveDownload': 'test'},
          },
          'downloadType': 1,
          '_downloadLink': url,
          '_currentBytes': 0,
          '_totalBytes': 64 * 1024 * 1024,
        }, () {}, error, () async => updated(), 'archive-test');

  @override
  String get path => folder;

  // The fixture supplies a directory and archive URL; no gallery API is needed.
  @override
  // ignore: must_call_super
  Future<void> onStart() async {}

  @override
  Future<void> downloadCover() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rapid archive resume waits for the old worker to checkpoint and close',
      () async {
    AppTranslation.translations = {};
    appdata.settings[8] = '';
    appdata.settings[79] = '2';
    appdata.settings[90] = '0';
    final directory =
        await Directory.systemTemp.createTemp('pica-archive-pause-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    const size = 64 * 1024 * 1024;
    final chunk = Uint8List(64 * 1024);
    var updates = 0;
    var errors = 0;
    server.listen((request) async {
      final response = request.response;
      response.headers.set('accept-ranges', 'bytes');
      if (request.method == 'HEAD') {
        response.contentLength = size;
        await response.close();
        return;
      }
      final range = RegExp(r'bytes=(\d+)-(\d+)')
          .firstMatch(request.headers.value('range')!)!;
      final start = int.parse(range[1]!);
      final end = int.parse(range[2]!) + 1;
      response.statusCode = 206;
      response.contentLength = end - start;
      response.headers.set('content-range', 'bytes $start-${end - 1}/$size');
      try {
        for (var position = start; position < end; position += chunk.length) {
          response
              .add(chunk.sublist(0, (end - position).clamp(0, chunk.length)));
          await response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await response.close();
      } on SocketException {
        // Both pauses deliberately cancel every active range request.
      } on HttpException {
        // A canceled response may end before its declared content length.
      }
    });
    final item = _ArchiveDownload(
        directory.path,
        'http://127.0.0.1:${server.port}/archive',
        () => updates++,
        () => errors++);
    Future<void> until(bool Function() ready) async {
      for (var i = 0; i < 500 && !ready(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(ready(), isTrue);
    }

    try {
      item.start();
      await until(() => item.downloadedPages > 0 || errors > 0);
      expect(errors, 0);
      final before = item.downloadedPages;
      final previousUpdates = updates;
      final pausing = item.pause();
      item.start();
      await pausing;
      await until(() => updates > previousUpdates || errors > 0);
      expect(errors, 0);
      expect(item.downloadedPages, greaterThanOrEqualTo(before));
      await item.pause();
      final lines =
          await File('${directory.path}/temp.zip.download').readAsLines();
      final committed = lines.fold<int>(
          0, (sum, line) => sum + int.parse(line.split('-')[2]));
      expect(committed, greaterThan(0));
      expect(committed, lessThan(size));
      expect(File('${directory.path}/temp.zip.download.tmp').existsSync(),
          isFalse);
    } finally {
      await item.pause();
      await server.close(force: true);
      expect(
          directory.absolute.path
              .startsWith(Directory.systemTemp.absolute.path),
          isTrue);
      expect(directory.uri.pathSegments.where((s) => s.isNotEmpty).last,
          startsWith('pica-archive-pause-'));
      await directory.delete(recursive: true);
    }
  });
}
