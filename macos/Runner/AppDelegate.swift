import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if MainFlutterWindow.isKioskLocked && !MainFlutterWindow.isExitingCleanly {
      return .terminateCancel
    }
    return .terminateNow
  }
}
