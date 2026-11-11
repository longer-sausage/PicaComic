import 'package:flutter/material.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/image_loader/cached_image.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/eh_network/eh_download_model.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:pica_comic/tools/download_runtime.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/components/components.dart';

class DownloadingPage extends StatefulWidget {
  const DownloadingPage({Key? key}) : super(key: key);

  @override
  State<DownloadingPage> createState() => _DownloadingPageState();
}

class _DownloadingPageState extends State<DownloadingPage> {
  var comics = <DownloadingItem>[];

  @override
  void dispose() {
    downloadManager.removeListener(onChange);
    super.dispose();
  }

  @override
  void initState() {
    downloadManager.addListener(onChange);
    comics = List.from(downloadManager.downloading);
    super.initState();
  }

  void onChange() {
    if(downloadManager.error) {
      setState(() {});
    } else if (downloadManager.downloading.length != comics.length) {
      rebuild();
    } else if (key.currentState != null){
      key.currentState!.updateUi();
    }
  }

  void rebuild() {
    key = GlobalKey<_DownloadingTileState>();
    setState(() {
      comics = List.from(downloadManager.downloading);
    });
  }

  var key = GlobalKey<_DownloadingTileState>();

  Future<void> showBackgroundDownloadSettings() async {
    bool? ignored;
    try {
      ignored = await DownloadRuntime.channel
          .invokeMethod<bool>('batteryOptimizationsIgnored');
    } catch (_) {
      // The system settings can still be opened if this status is unavailable.
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('后台下载设置'.tl),
        content: Text([
          if (ignored == true) '已允许忽略电池优化'.tl,
          '在系统电池设置中将 Pica Comic 设为“不受限制”或“不优化”，可减少后台和锁屏时的下载降速。'.tl,
        ].join('\n\n')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('取消'.tl),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              try {
                await DownloadRuntime.channel.invokeMethod<void>('batterySettings');
              } catch (_) {
                if (mounted) showToast(message: '无法打开系统设置'.tl);
              }
            },
            child: Text('打开电池设置'.tl),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    var widgets = <Widget>[];
    for (var i in comics) {
      var key = Key(i.id);
      if(i == comics.first) {
        key = this.key;
      }

      widgets.add(_DownloadingTile(
        comic: i,
        cancel: () {
          showConfirmDialog(context, "取消".tl, "取消下载任务?".tl, () {
            setState(() {
              downloadManager.cancel(i.id);
            });
          });
        },
        onComicPositionChange: rebuild,
        key: key,
      ));
    }

    final body = ListView.builder(
        itemCount: downloadManager.downloading.length + 1,
        padding: EdgeInsets.zero,
        itemBuilder: (context, index) {
          if (index == 0) {
            String downloadStatus;
            if (downloadManager.isDownloading) {
              downloadStatus = " 下载中".tl;
            } else if (downloadManager.downloading.isNotEmpty) {
              downloadStatus = " 已暂停".tl;
            } else {
              downloadStatus = "";
            }

            String downloadTaskText = "@length 项下载任务".tlParams(
                {"length": downloadManager.downloading.length.toString()});

            String displayText = downloadManager.error
                ? "下载出错".tl
                : downloadTaskText + downloadStatus;
            return Container(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                height: 48,
                child: Row(
                  children: [
                    const SizedBox(
                      width: 16,
                    ),
                    downloadManager.isDownloading
                        ? const Icon(
                            Icons.downloading,
                            color: Colors.blue,
                          )
                        : const Icon(
                            Icons.pause_circle_outline_outlined,
                            color: Colors.red,
                          ),
                    const SizedBox(
                      width: 12,
                    ),
                    Text(displayText),
                    const Spacer(),
                    if (downloadManager.downloading.isNotEmpty)
                      TextButton(
                        onPressed: () {
                          downloadManager.isDownloading
                              ? downloadManager.pause()
                              : downloadManager.start();
                          setState(() {});
                        },
                        child: downloadManager.isDownloading
                            ? Text("暂停".tl)
                            : (downloadManager.error
                                ? Text("重试".tl)
                                : Text("继续".tl)),
                      ),
                    const SizedBox(
                      width: 16,
                    ),
                  ],
                ));
          } else {
            return widgets[index - 1];
          }
        });

    return PopUpWidgetScaffold(
      title: "下载管理器".tl,
      tailing: App.isAndroid ? [
        IconButton(
          onPressed: showBackgroundDownloadSettings,
          tooltip: '后台下载设置'.tl,
          icon: const Icon(Icons.battery_saver_outlined),
        ),
      ] : null,
      body: body,
    );
  }
}

class _DownloadingTile extends StatefulWidget {
  const _DownloadingTile({
    required this.comic,
    required this.cancel,
    required this.onComicPositionChange,
    super.key,
  });

  final DownloadingItem comic;

  final void Function() cancel;

  final void Function() onComicPositionChange;

  @override
  State<_DownloadingTile> createState() => _DownloadingTileState();
}

class _DownloadingTileState extends State<_DownloadingTile> {
  late DownloadingItem comic;

  double value = 0.0;
  int downloadPages = 0;
  int? pagesCount;
  int? speed;

  @override
  initState() {
    super.initState();
    comic = widget.comic;
    updateStatistic();
  }

  @override
  void didUpdateWidget(covariant _DownloadingTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.comic != comic) {
      setState(() {
        comic = widget.comic;
      });
    }
  }

  void updateStatistic() {
    if(comic != DownloadManager().downloading.first) {
      return;
    }
    comic = DownloadManager().downloading.first;
    speed = comic.currentSpeed;
    downloadPages = comic.downloadedPages;
    pagesCount = comic.totalPages;
    if (pagesCount == 0) {
      pagesCount = null;
    }
    if (pagesCount != null && pagesCount! > 0) {
      value = downloadPages / pagesCount!;
    }
  }

  void updateUi() {
    setState(() {
      updateStatistic();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: SizedBox(
        height: 114,
        width: double.infinity,
        child: Row(
          children: [
            Container(
              width: 84,
              height: double.infinity,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: context.colorScheme.secondaryContainer,
              ),
              clipBehavior: Clip.antiAlias,
              child: AnimatedImage(
                image: CachedImageProvider(comic.cover,
                    headers: {"User-Agent": webUA}),
                width: 84,
                height: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    comic.title,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Spacer(),
                  Text(
                    getProgressText(),
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: value),
                  const SizedBox(height: 4),
                ],
              ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 50,
              child: Column(
                children: [
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: widget.cancel,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.vertical_align_top),
                    onPressed: () {
                      DownloadManager().moveToFirst(comic);
                      widget.onComicPositionChange();
                    },
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _bytesToSize(int bytes) {
    if (bytes < 1024) {
      return "$bytes B";
    } else if (bytes < 1024 * 1024) {
      return "${(bytes / 1024).toStringAsFixed(2)} KB";
    } else if (bytes < 1024 * 1024 * 1024) {
      return "${(bytes / 1024 / 1024).toStringAsFixed(2)} MB";
    } else {
      return "${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB";
    }
  }

  String getProgressText() {
    if (pagesCount == null) {
      if (comic == DownloadManager().downloading.first) {
        return "获取图片信息...".tl;
      } else {
        return "";
      }
    }

    String speedInfo = "";
    if (speed != null) {
      speedInfo = "${_bytesToSize(speed!)}/s";
    }

    String status = "${"已下载".tl}$downloadPages/$pagesCount";

    if (comic is EhDownloadingItem
        && (comic as EhDownloadingItem).downloadType != 0) {
      status = "${_bytesToSize(downloadPages).split(' ').first}"
          "/${_bytesToSize(pagesCount!)}";
    }

    final isActive = DownloadManager().isDownloading &&
        comic == DownloadManager().downloading.firstOrNull;
    final parallel = isActive
        ? '  ${'并行 @count'.tlParams({'count': comic.allowedLoadingNumber.toString()})}'
        : '';
    return "$status  $speedInfo$parallel";
  }
}
