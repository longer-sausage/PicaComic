# 后台下载

目标是在系统允许的范围内，让切到后台后的下载尽可能保持前台吞吐量。所有漫画源、
收藏下载和 E-Hentai 压缩包下载都由下载管理器统一申请、释放运行保护。

## 平台行为

| 平台 | 下载期间的保护 | 系统边界 |
| --- | --- | --- |
| Android | `dataSync` 前台服务、部分 CPU 唤醒锁、Wi-Fi 性能锁 | Doze、电池优化、厂商策略和系统服务时限仍可能限制运行 |
| Windows | `SetThreadExecutionState` 防止空闲休眠，允许屏幕关闭 | 用户主动休眠和关机仍由系统处理 |
| macOS | `ProcessInfo` 活动声明，避免 App Nap 和空闲休眠 | 系统或用户仍可终止进程、主动休眠 |
| Linux | GTK 会话管理器的休眠抑制请求 | 需要桌面会话管理器支持，拒绝请求时记录日志并继续下载 |
| iOS | 下载开始前申请有限的后台执行时间 | 系统时间到期时保存队列、暂停；返回前台后继续，手动暂停会取消自动继续 |

Android 服务在开始下载前建立，保持到整个队列结束；切换应用时不停止服务。
暂停、取消最后一项、出错、销毁下载管理器或 Flutter 引擎时停止服务并释放锁。
服务不会脱离 Dart 下载任务自行重启。进度通知由服务持有，每秒最多刷新一次，
压缩包按字节报告进度。CPU 锁有超时保护，服务在有效下载期间定时续期。

Wi-Fi 性能锁在旧系统上有助于减少熄屏后的 Wi-Fi 节电降速。Android 14 起，系统将
`WIFI_MODE_FULL_HIGH_PERF` 映射为低延迟模式，效果受前台和屏幕状态限制，不能仅靠
Wi-Fi 锁保证熄屏满速。参见 [WifiManager 官方说明](https://developer.android.com/reference/android/net/wifi/WifiManager#WIFI_MODE_FULL_HIGH_PERF)。

下载管理器右上角的电池按钮可查看电池优化状态并进入系统设置。需要时将 Pica Comic
设为“不受限制”或“不优化”。用户主动配置的豁免可允许 Doze 期间访问网络、持有
部分唤醒锁；应用不会自动修改该设置。参见 [Doze 官方说明](https://developer.android.com/training/monitoring-device-state/doze-standby)。

面向 Android 15 及以上的 `dataSync` 服务有后台运行时限，服务实现了 `onTimeout`
及时释放资源，并通知 Dart 保存、暂停队列。参见 [前台服务时限](https://developer.android.com/develop/background-work/services/fgs/timeout)。
iOS 的普通 Dart 网络请求无法无限后台运行，本次使用系统授予的延长时间，
参见 [Apple 后台执行说明](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)。

## 队列与并发

平台调用按顺序执行，快速暂停、继续时旧的停止操作不会覆盖新的启动。
下载状态在每次启动时分配序号，暂停后的元数据、封面、重试和压缩包回调不能重新启动旧任务。
取消排队任务不重新启动当前任务；暂停中的队列也不会因为取消一项而继续下载。
任务完成并写入数据库期间发生的暂停或切换，优先保留用户的新操作。

多张图片完成时产生的进度保存按顺序写入同一队列文件，并合并过期快照，避免并行写入
导致内容截断。系统要求暂停时，最新队列写入完成并刷盘后才确认处理完毕。

## 验证

```shell
flutter test --no-pub
flutter test --no-pub test/download_runtime_test.dart test/download_manager_lifecycle_test.dart test/download_item_lifecycle_test.dart
flutter build apk --release --no-pub --target-platform android-arm64,android-x64
```

2026-11-11，Windows 本机 Flutter 3.35.7 / Dart 3.9.2：全部 98 项测试通过，
其中 21 项覆盖下载运行保护、暂停/继续竞态、后台到期保存、任务完成交错、并发保存和延迟回调。
Android Release 构建通过；Windows 原生窗口代码通过 MSVC C++17 语法检查。

Android 12 / API 32 模拟器使用独立测试包，6 个并发 HTTP 下载通过本机回环服务和
`adb reverse` 连续读取数据。前台平均约 99 MiB/s；切到桌面后，在 21.54–72.54 秒
区间平均约 115 MiB/s，下载持续进行。后台期间通过 `dumpsys` 确认服务仍为前台服务，
CPU 和 Wi-Fi 锁均持有；下载结束后服务及两种锁均已释放。测试包和端口转发已移除，
没有覆盖现有应用或修改其数据。这组数据只说明该模拟器和本机链路上的后台持续运行情况。

该模拟器未实际关闭显示，因此熄屏、强制 Doze、Android 15+ 原生超时仍需对应设备实测。
iOS、macOS、Linux 的原生构建与运行，以及 Windows 的完整构建也需要对应环境验证。

建议实机用同一漫画源、同一网络分别下载 60 秒，比较前台、切到桌面和熄屏时的平均速度。
同时检查暂停、出错、全部完成后通知和电源锁是否释放。允许忽略电池优化后，再验证 Doze：

```shell
adb shell dumpsys battery unplug
adb shell dumpsys deviceidle force-idle
adb shell dumpsys activity services com.github.longersausage.pica_comic
adb shell dumpsys power
adb shell dumpsys wifi
# 验证结束后恢复系统状态
adb shell dumpsys deviceidle unforce
adb shell dumpsys battery reset
```

Android 15+ 可按官方文档临时缩短 `data_sync_fgs_timeout_duration`，检查到期暂停、
队列保存和回到前台后继续的行为；测试完成后恢复原有设置。
