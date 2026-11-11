import UIKit
import Flutter
import flutter_local_notifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var downloadTask: UIBackgroundTaskIdentifier = .invalid
  private var downloadChannel: FlutterMethodChannel?

  private func endDownloadTask(_ expectedTask: UIBackgroundTaskIdentifier? = nil) {
    guard downloadTask != .invalid else { return }
    if let expectedTask = expectedTask, downloadTask != expectedTask { return }
    UIApplication.shared.endBackgroundTask(downloadTask)
    downloadTask = .invalid
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller: FlutterViewController = window?.rootViewController as! FlutterViewController

    let downloads = FlutterMethodChannel(
      name: "com.github.pacalini.pica_comic/download",
      binaryMessenger: controller.binaryMessenger)
    downloadChannel = downloads
    downloads.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      switch call.method {
      case "start":
        if self.downloadTask == .invalid {
          // Register before entering the background so Dart workers can continue
          // for the time granted by iOS. This is not an unlimited background mode.
          self.downloadTask = application.beginBackgroundTask(withName: "Comic downloads") { [weak self] in
            guard let self = self else { return }
            let expiringTask = self.downloadTask
            self.downloadChannel?.invokeMethod("expired", arguments: nil) { [weak self] _ in
              self?.endDownloadTask(expiringTask)
            }
            // Always finish the task, even if the Dart isolate cannot respond.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
              self?.endDownloadTask(expiringTask)
            }
          }
          if self.downloadTask == .invalid {
            result(FlutterError(code: "background_task", message: "iOS denied background execution", details: nil))
            return
          }
        }
        result(nil)
      case "stop":
        self.endDownloadTask()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { (registry) in
      GeneratedPluginRegistrant.register(with: registry)
    }

    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    }

    // 用于获取系统代理配置的 MethodChannel
    let methodChannel = FlutterMethodChannel(name: "com.github.pacalini.pica_comic/proxy", binaryMessenger: controller.binaryMessenger)
    methodChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
        if let proxySettings = CFNetworkCopySystemProxySettings()?.takeUnretainedValue() as NSDictionary?,
           let dict = proxySettings.object(forKey: kCFNetworkProxiesHTTPProxy) as? NSDictionary,
           let host = dict.object(forKey: kCFNetworkProxiesHTTPProxy) as? String,
           let port = dict.object(forKey: kCFNetworkProxiesHTTPPort) as? Int {
            let proxyConfig = "\(host):\(port)"
            result(proxyConfig)
        } else {
            result("")
        }
    }

    // 用于设置屏幕常亮的 MethodChannel
    let channel2 = FlutterMethodChannel(name: "com.github.pacalini.pica_comic/keepScreenOn", binaryMessenger: controller.binaryMessenger)
    channel2.setMethodCallHandler { (call: FlutterMethodCall, result: FlutterResult) in
      if call.method == "set" {
        let screenOn = true // 设置屏幕常亮
        UIApplication.shared.isIdleTimerDisabled = screenOn
      } else {
        let screenOn = false // 设置屏幕不常亮
        UIApplication.shared.isIdleTimerDisabled = screenOn
      }
      result(nil)
    }

    // 用于监听音量键的 MethodChannel
    let volumeChannel = FlutterEventChannel(name: "com.github.pacalini.pica_comic/volume", binaryMessenger: controller.binaryMessenger)
    volumeChannel.setStreamHandler(VolumeStreamHandler())

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

class VolumeStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
