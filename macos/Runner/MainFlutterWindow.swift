import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Kiosk Lockdown flag for macOS (active only during exam session)
  static var isKioskLocked: Bool = false
  static var isOfficeSessionActive: Bool = false
  static var isExitingCleanly: Bool = false

  private var kioskChannel: FlutterMethodChannel?
  private var localSwipeMonitor: Any?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    RegisterGeneratedPlugins(registry: flutterViewController)

    setupMethodChannels(messenger: flutterViewController.engine.binaryMessenger)
    setupLifecycleAndWorkspaceObservers()
    setupLocalEventMonitors()

    super.awakeFromNib()

    // Start in Normal macOS window mode by default; Kiosk Lockdown engages only during active exam
    DispatchQueue.main.async { [weak self] in
      self?.applyKioskMode(enabled: false)
    }
  }

  deinit {
    if let monitor = localSwipeMonitor {
      NSEvent.removeMonitor(monitor)
    }
    NotificationCenter.default.removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  // MARK: - MethodChannel Setup

  private func setupMethodChannels(messenger: FlutterBinaryMessenger) {
    let macChannel = FlutterMethodChannel(name: "ara_desktop/macos_kiosk", binaryMessenger: messenger)
    self.kioskChannel = macChannel
    macChannel.setMethodCallHandler { [weak self] (call, result) in
      self?.handleMethodCall(call, result: result)
    }

    // Parity with Windows desktop kiosk channel
    let hookChannel = FlutterMethodChannel(name: "ara_desktop/kiosk_hook", binaryMessenger: messenger)
    hookChannel.setMethodCallHandler { [weak self] (call, result) in
      self?.handleMethodCall(call, result: result)
    }
  }

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setKioskLockdown", "setHook", "setWindowLock":
      let args = call.arguments as? [String: Any]
      let enabled = args?["enabled"] as? Bool ?? args?["locked"] as? Bool ?? true
      MainFlutterWindow.isKioskLocked = enabled
      DispatchQueue.main.async { [weak self] in
        self?.applyKioskMode(enabled: enabled)
      }
      result(true)

    case "setOfficeSession":
      let args = call.arguments as? [String: Any]
      let active = args?["active"] as? Bool ?? false
      MainFlutterWindow.isOfficeSessionActive = active
      DispatchQueue.main.async { [weak self] in
        self?.evaluateOfficeSessionWindowLevel()
      }
      result(true)

    case "forceForeground":
      DispatchQueue.main.async { [weak self] in
        self?.forceForeground()
      }
      result(true)

    case "exitApp":
      DispatchQueue.main.async { [weak self] in
        self?.cleanExitApp()
      }
      result(true)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Kiosk Lockdown Engine

  func applyKioskMode(enabled: Bool) {
    if enabled {
      // 1. Pinned to all spaces, stationary, auxiliary:
      // - canJoinAllSpaces: Window exists across ALL macOS Spaces (virtual desktops).
      //   Swiping 3 fingers left or right CANNOT slide the window away or reveal other spaces!
      // - fullScreenAuxiliary: Window stays on screen across desktop spaces without creating a separate Space.
      // - stationary: Window does not move or animate during Mission Control or Space switches.
      // - ignoresCycle: Window is omitted from Cmd+` window cycling.
      self.collectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .stationary,
        .ignoresCycle
      ]

      // 2. High window level:
      // .screenSaver is above normal desktop windows, Dock, and Menu Bar.
      self.level = MainFlutterWindow.isOfficeSessionActive ? .normal : .screenSaver

      // 3. Borderless full screen frame covering active display:
      self.styleMask = [.borderless]
      if let screen = NSScreen.main {
        self.setFrame(screen.frame, display: true)
      }

      // 4. Kiosk Presentation Options:
      // - disableProcessSwitching: Disables Cmd+Tab, Exposé, and Mission Control 3/4-finger gestures!
      // - hideDock: Completely hides the Dock.
      // - hideMenuBar: Completely hides the Menu Bar.
      // - disableForceQuit: Disables Cmd+Option+Esc.
      // - disableHideApplication: Disables Cmd+H.
      // - disableSessionTermination: Disables logout/restart/shutdown.
      // - disableAppleMenu: Disables the Apple menu.
      let kioskOptions: NSApplication.PresentationOptions = [
        .hideDock,
        .hideMenuBar,
        .disableProcessSwitching,
        .disableForceQuit,
        .disableSessionTermination,
        .disableHideApplication,
        .disableAppleMenu
      ]
      NSApp.presentationOptions = kioskOptions

      self.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    } else {
      // Unlocked / normal mode (e.g. supervisor override or before exam)
      NSApp.presentationOptions = []
      self.level = .normal
      self.title = "ARA Assessment"
      self.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      self.collectionBehavior = [.managed]
      if let screen = NSScreen.main {
        let width: CGFloat = 1366
        let height: CGFloat = 768
        let x = (screen.frame.width - width) / 2 + screen.frame.origin.x
        let y = (screen.frame.height - height) / 2 + screen.frame.origin.y
        self.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
      }
    }
  }

  // MARK: - Lifecycle & Workspace Watchdog

  private func setupLifecycleAndWorkspaceObservers() {
    // Detect when any application on macOS activates
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(handleWorkspaceAppActivation(_:)),
      name: NSWorkspace.didActivateApplicationNotification,
      object: nil
    )

    // Detect when ARA loses active application status
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppDidResignActive(_:)),
      name: NSApplication.didResignActiveNotification,
      object: nil
    )

    // Detect when ARA loses key window status
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleWindowDidResignKey(_:)),
      name: NSWindow.didResignKeyNotification,
      object: self
    )
  }

  @objc private func handleWorkspaceAppActivation(_ notification: Notification) {
    guard MainFlutterWindow.isKioskLocked && !MainFlutterWindow.isExitingCleanly else { return }
    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
      return
    }

    let bundleId = app.bundleIdentifier ?? ""
    let appName = (app.localizedName ?? "").lowercased()

    if bundleId == Bundle.main.bundleIdentifier {
      if !MainFlutterWindow.isOfficeSessionActive {
        self.level = .screenSaver
      }
      return
    }

    let isOfficeApp = bundleId == "com.microsoft.Word" ||
                      bundleId == "com.microsoft.Excel" ||
                      bundleId == "com.microsoft.Powerpoint" ||
                      appName.contains("microsoft word") ||
                      appName.contains("microsoft excel") ||
                      appName.contains("microsoft powerpoint")

    if MainFlutterWindow.isOfficeSessionActive && isOfficeApp {
      // Allowed Office app during authorized exam office session
      self.level = .normal
      return
    }

    // Unauthorized app switch attempt! Pull focus immediately back to ARA Assessment!
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.forceForeground()
      self.kioskChannel?.invokeMethod("onNavigationBlocked", arguments: ["reason": "minimize"])
    }
  }

  @objc private func handleAppDidResignActive(_ notification: Notification) {
    guard MainFlutterWindow.isKioskLocked && !MainFlutterWindow.isExitingCleanly && !MainFlutterWindow.isOfficeSessionActive else { return }
    DispatchQueue.main.async { [weak self] in
      self?.forceForeground()
      self?.kioskChannel?.invokeMethod("onNavigationBlocked", arguments: ["reason": "minimize"])
    }
  }

  @objc private func handleWindowDidResignKey(_ notification: Notification) {
    guard MainFlutterWindow.isKioskLocked && !MainFlutterWindow.isExitingCleanly && !MainFlutterWindow.isOfficeSessionActive else { return }
    DispatchQueue.main.async { [weak self] in
      self?.forceForeground()
    }
  }

  func forceForeground() {
    self.level = .screenSaver
    NSApp.activate(ignoringOtherApps: true)
    self.makeKeyAndOrderFront(nil)
  }

  private func evaluateOfficeSessionWindowLevel() {
    if MainFlutterWindow.isOfficeSessionActive {
      self.level = .normal
    } else if MainFlutterWindow.isKioskLocked {
      self.level = .screenSaver
      self.forceForeground()
    }
  }

  // MARK: - Trackpad Gesture & Event Filters

  private func setupLocalEventMonitors() {
    localSwipeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.swipe]) { _ in
      // Swallow local swipe events
      return nil
    }
  }

  override func swipe(with event: NSEvent) {
    // Consume and ignore trackpad swipe gestures
  }

  override func scrollWheel(with event: NSEvent) {
    // Consume high-magnitude horizontal gesture scrolls (page swipe)
    if MainFlutterWindow.isKioskLocked && event.phase != [] && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) && abs(event.scrollingDeltaX) > 20 {
      return
    }
    super.scrollWheel(with: event)
  }

  override var canBecomeKey: Bool {
    return true
  }

  override var canBecomeMain: Bool {
    return true
  }

  // MARK: - Clean Exit

  func cleanExitApp() {
    MainFlutterWindow.isExitingCleanly = true
    MainFlutterWindow.isKioskLocked = false
    NSApp.presentationOptions = []
    self.level = .normal
    NSApp.terminate(nil)
  }
}
