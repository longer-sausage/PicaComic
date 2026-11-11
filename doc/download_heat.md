# 安卓并行下载的额外资源消耗

本次保留原有手动并发数、自动并发探测、HTTP 连接池、后台前台服务和电源锁，
通过减少下载路径中的重复计算和写入降低 CPU、文件系统开销。

## 排查结果和修复

`CachingFile.close()` 原来在每张图片完成后调用 `checkCache()`，后者每次都用
`compute` 启动 isolate，递归遍历整个缓存目录并逐个读取文件大小。扫描没有等待完成，
多路下载会让多次全目录扫描重叠执行；已有缓存越多，额外开销越大。

现在启动时只扫描一次。首次扫描结束后才允许写入和删除，避免初始统计覆盖新进度；
之后按每个文件提交、替换、取消、删除的实际大小增减总量。缓存元数据及清理操作
串行处理，网络传输和数据文件写入仍然并行。普通过期清理最多每分钟执行一次，
容量和 2000 个文件的上限仍在每次提交时检查，手动检查会立即清理。
保留现有 SQLite 表结构和缓存格式。

同时修复清理循环：文件数量上限和容量上限分别判断，删除记录后均更新计数，
数据库已无可清理记录时退出，避免孤立文件导致空循环。提交失败不会阻塞后续操作，
重复关闭缓存文件不会重复计入大小，取消旧文件不会删除同一键的新版本。

禁漫图片原来在重组 isolate 内写入一次文件，返回后缓存管理器又追加一次相同内容。
现在重组 isolate 只返回结果，缓存管理器统一写入一次。网络数据改用
`BytesBuilder(copy: false)`，减少逐字节扩容和完整数据复制；重组前后检查取消状态。
带查询参数或大写扩展名的 GIF 也会保留原数据，避免误入 JPEG 重组路径。

## 对照基准

`tool/download_heat_workload.dart` 通过实际 `DownloadingItem`、`ImageManager`、
`CacheManager` 和 HTTP 回环服务器运行下载。预先放置 1800 个 1 KiB 缓存文件，
再下载 120 张 256 KiB 图片，共 30 MiB；每次响应等待 25 ms，固定并发数用于
比较相同条件。每张最终下载文件均检查长度和 SHA-256，请求数必须恰好为 120。

耗时从开始下载到全部页面完成；CPU 时间累计整个进程及其 isolate/线程，
额外包含下载结束后 2 秒，计入这段时间内仍在运行的后台扫描。种子准备、初始扫描及
最终文件校验不计入下载耗时和 CPU 样本。

2026-11-11，Windows，Flutter 3.35.7 / Dart 3.9.2，首轮结果：

| 并发 | 修改前耗时 | 修改后耗时 | 修改前 CPU 时间 | 修改后 CPU 时间 |
| --- | ---: | ---: | ---: | ---: |
| 6 | 4.338 s | 2.298 s | 60.859 s | 2.547 s |
| 16 | 4.669 s | 2.206 s | 63.219 s | 2.516 s |

该合成负载下，累计 CPU 时间减少约 96%，下载吞吐量提高。CPU 时间是多线程累计值，
可以大于实际耗时。这些结果衡量软件开销，不等于手机温度或功耗测量；真实源站的
限流、无线网络、图片重组和设备存储仍影响下载速度及温升。

Android 12 / API 32 / x86_64 测试环境，使用独立包名
`com.github.longersausage.pica_comic.heatbenchmark`，相同 Release 构建参数、
16 路并发，修改前基线为 `552c8405`。两版分别运行 3 次：

| 版本 | 下载耗时，三次 | 累计 CPU 时间，三次 |
| --- | --- | --- |
| 修改前 | 4.249 / 4.235 / 4.549 s | 10.32 / 10.45 / 8.74 s |
| 修改后 | 1.120 / 0.910 / 0.777 s | 0.72 / 0.56 / 0.63 s |

中位数：下载耗时 **4.249 → 0.910 s**，吞吐量约 **7.06 → 32.97 MiB/s**；
累计 CPU 时间 **10.32 → 0.63 s**，减少约 **94%**。全部 720 张页面的最终文件
通过长度和 SHA-256 校验。测试应用只使用生成数据和自己的私有目录，完成后已卸载。
测试未覆盖真实源站、无线网络或真机温度，不能据此换算具体降温度数。

## 复现和回归

```shell
flutter test --no-pub
flutter test --no-pub tool/benchmark_download_heat.dart --dart-define=BENCH_CONCURRENCY=6 --reporter expanded
flutter test --no-pub tool/benchmark_download_heat.dart --dart-define=BENCH_CONCURRENCY=16 --reporter expanded
flutter build apk --release --no-pub --target-platform android-arm64,android-x64
```

基准会输出 `DOWNLOAD_HEAT_BENCHMARK` JSON 和临时目录位置。桌面进程退出后可以
删除该目录。Android 入口为 `tool/benchmark_download_heat_android.dart`，应在独立
checkout 中使用独立 applicationId 构建和安装，以免覆盖正常应用及数据。

`test/cache_manager_test.dart` 覆盖并行缓冲写入、大小恢复、重复关闭、同键替换、
取消与替换交错、过期清理、容量与文件数限制、失败后恢复、孤立文件，以及禁漫
缓存无重复内容和 GIF 数据保留。完整回归共 130 项通过。

Android 正式 Release 构建（arm64 + x86_64）通过；上述变更文件和基准脚本的
`dart analyze` 无问题。独立测试 worktree 已从 Git 登记中移除；Windows 长路径导致
临时目录未能全部删除，后续文件清理被自动审批拦截（仅返回 `blocked by policy`）。
剩余文件位于 `E:\TEMP\pica-heat-validation`，两份测试 APK 位于项目的
`.dart_tool/heat-before.apk` 和 `.dart_tool/heat-after.apk`；均未发布。Android 测试应用已卸载。
