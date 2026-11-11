import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/tools/translations.dart';

class _PendingDownload extends DownloadingItem {
  final metadata = Completer<Map<int, List<String>>>();
  Completer<void>? pendingCover;
  final images = StreamController<DownloadProgress>.broadcast();
  int coverRequests = 0;
  int imageRequests = 0;

  _PendingDownload()
      : super(null, null, null, 'pending', type: DownloadType.picacg) {
    directory = 'pending';
  }

  @override
  String get title => 'Pending comic';

  @override
  String get cover => '';

  @override
  String get path => Directory.systemTemp.path;

  @override
  Future<Map<int, List<String>>> getLinks() => metadata.future;

  @override
  Future<void> downloadCover() async {
    coverRequests++;
    await pendingCover?.future;
  }

  @override
  Stream<DownloadProgress> downloadImage(String link) {
    imageRequests++;
    return images.stream;
  }

  @override
  Map<String, dynamic> toMap() => toBaseMap();

  @override
  DownloadedItem toDownloadedItem() => throw UnimplementedError();
}

class _RetryDownload extends _PendingDownload {
  int starts = 0;

  @override
  void start() => starts++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => AppTranslation.translations = {});

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('metadata arriving after pause cannot start cover, images or recorder',
      () async {
    final item = _PendingDownload();
    item.start();
    await settle();
    item.pause();
    item.metadata.complete({
      0: ['image']
    });
    await settle();
    expect(item.coverRequests, 0);
    expect(item.imageRequests, 0);
    expect(item.timer, isNull);
    await item.images.close();
  });

  test('cover arriving after pause cannot restart images or recorder',
      () async {
    final item = _PendingDownload();
    item.metadata.complete({
      0: ['image']
    });
    item.pendingCover = Completer<void>();
    item.start();
    await settle();
    expect(item.coverRequests, 1);
    item.pause();
    item.pendingCover!.complete();
    await settle();
    expect(item.imageRequests, 0);
    expect(item.timer, isNull);
    await item.images.close();
  });

  test('a stale request cannot duplicate transfers after immediate resume',
      () async {
    final item = _PendingDownload();
    item.start();
    await settle();
    item.pause();
    item.start();
    item.metadata.complete({
      0: ['image']
    });
    await settle();
    expect(item.coverRequests, 1);
    expect(item.imageRequests, 1);
    item.pause();
    await item.images.close();
    expect(item.timer, isNull);
  });

  testWidgets('a scheduled retry cannot restart a paused download',
      (tester) async {
    final item = _RetryDownload();
    final retry = item.retry();
    item.pause();
    await tester.pump(const Duration(seconds: 5));
    await retry;
    expect(item.starts, 0);
    await item.images.close();
  });
}
