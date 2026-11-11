import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow  {
  private var downloadActivity: NSObjectProtocol?

  private func endDownloadActivity() {
    if let activity = downloadActivity {
      ProcessInfo.processInfo.endActivity(activity)
      downloadActivity = nil
    }
  }

  deinit {
    endDownloadActivity()
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController.init()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let downloads = FlutterMethodChannel(
      name: "com.github.pacalini.pica_comic/download",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    downloads.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      switch call.method {
      case "start":
        if self.downloadActivity == nil {
          self.downloadActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Downloading comics")
        }
        result(nil)
      case "stop":
        self.endDownloadActivity()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
