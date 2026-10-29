import Cocoa
import FlutterMacOS
import ObjectiveC.runtime
import Security
import WebKit
import flutter_inappwebview_macos

class MainFlutterWindow: NSWindow {
  /// Kiosk Lockdown flag for macOS (active only during exam session)
  static var isKioskLocked: Bool = false
  static var isOfficeSessionActive: Bool = false
  static var isExitingCleanly: Bool = false

  /// Allowed macOS system UI / TCC permission / security helper bundle IDs that must never be
  /// fought by the foreground watchdog when presenting camera/microphone/file sheets.
  private static let allowedSystemBundlePrefixes: [String] = [
    "com.apple.universalAccessAuthWarn",
    "com.apple.CoreServicesUIAgent",
    "com.apple.UserNotificationCenter",
    "com.apple.securityagent",
    "com.apple.SecurityAgent",
    "com.apple.screencaptureui",
    "com.apple.controlcenter",
    "com.apple.appkit.xpc.openAndSavePanelService",
    "com.apple.Safari.SandboxBroker",
    "com.apple.WebKit."
  ]

  private var kioskChannel: FlutterMethodChannel?
  private var localSwipeMonitor: Any?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    RegisterGeneratedPlugins(registry: flutterViewController)
    InAppWebView.installAraSslCertificateBypass()

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

      // 2. Keep .normal window level:
      // Using .normal (instead of .screenSaver = 1000) ensures that any native dialog,
      // NSAlert, NSOpenPanel, <select> popup menu, or macOS TCC Camera/Microphone permission
      // sheet is NEVER buried behind MainFlutterWindow (which previously caused macOS AppKit
      // to play NSBeep() on every click and ignore all input).
      // Dock, Menu Bar, Cmd+Tab, and Mission Control remain 100% locked via NSApp.presentationOptions.
      self.level = .normal

      // 3. Frameless full-screen appearance while preserving .titled (NSThemeFrame):
      // Dynamically stripping .titled into [.borderless] on a mounted FlutterMacOS window
      // recreates the window frame view and detaches WKWebView's responder chain.
      // Keeping [.titled, .fullSizeContentView] with a hidden titlebar preserves WKWebView click/key focus.
      self.styleMask = [.titled, .fullSizeContentView]
      self.titleVisibility = .hidden
      self.titlebarAppearsTransparent = true
      self.isMovable = false
      self.isMovableByWindowBackground = false
      setWindowControlButtonsHidden(true)

      if let screen = NSScreen.main ?? self.screen {
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
      restoreWebViewFirstResponderIfNeeded()
    } else {
      // Unlocked / normal mode (e.g. supervisor override or before exam)
      NSApp.presentationOptions = []
      self.level = .normal
      self.title = "ARA Assessment"
      self.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      self.titleVisibility = .visible
      self.titlebarAppearsTransparent = false
      self.isMovable = true
      self.isMovableByWindowBackground = false
      setWindowControlButtonsHidden(false)
      self.collectionBehavior = [.managed]
      if let screen = NSScreen.main ?? self.screen {
        let width: CGFloat = 1366
        let height: CGFloat = 768
        let x = (screen.frame.width - width) / 2 + screen.frame.origin.x
        let y = (screen.frame.height - height) / 2 + screen.frame.origin.y
        self.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
      }
      restoreWebViewFirstResponderIfNeeded()
    }
  }

  private func setWindowControlButtonsHidden(_ hidden: Bool) {
    let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    for type in buttonTypes {
      if let btn = self.standardWindowButton(type) {
        btn.isHidden = hidden
        btn.isEnabled = !hidden
      }
    }
    if let titlebarContainer = self.standardWindowButton(.closeButton)?.superview?.superview {
      titlebarContainer.isHidden = hidden
    }
  }

  private func restoreWebViewFirstResponderIfNeeded() {
    guard NSApp.modalWindow == nil && self.attachedSheet == nil else { return }
    if let rootView = self.contentView, let webView = findWebView(in: rootView) {
      if self.firstResponder === self || self.firstResponder == nil {
        self.makeFirstResponder(webView)
      }
    } else if let flutterView = self.contentViewController?.view {
      if self.firstResponder === self || self.firstResponder == nil {
        self.makeFirstResponder(flutterView)
      }
    }
  }

  private func findWebView(in view: NSView) -> WKWebView? {
    if let webView = view as? WKWebView {
      return webView
    }
    for subview in view.subviews {
      if let found = findWebView(in: subview) {
        return found
      }
    }
    return nil
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

  private func hasActiveModalOrSheet() -> Bool {
    if NSApp.modalWindow != nil || self.attachedSheet != nil {
      return true
    }
    if let children = self.childWindows, !children.isEmpty {
      return true
    }
    return false
  }

  @objc private func handleWorkspaceAppActivation(_ notification: Notification) {
    guard MainFlutterWindow.isKioskLocked && !MainFlutterWindow.isExitingCleanly else { return }
    guard !hasActiveModalOrSheet() else { return }
    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
      return
    }

    let bundleId = app.bundleIdentifier ?? ""
    let appName = (app.localizedName ?? "").lowercased()

    if bundleId == Bundle.main.bundleIdentifier {
      return
    }

    // Allow macOS system permission/security/open-panel helper processes
    if MainFlutterWindow.allowedSystemBundlePrefixes.contains(where: { bundleId.hasPrefix($0) }) {
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
    guard !hasActiveModalOrSheet() else { return }

    // Check if the newly active app is a system TCC/security helper before forcing foreground
    if let frontApp = NSWorkspace.shared.frontmostApplication,
       let bundleId = frontApp.bundleIdentifier,
       MainFlutterWindow.allowedSystemBundlePrefixes.contains(where: { bundleId.hasPrefix($0) }) {
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.hasActiveModalOrSheet() else { return }
      self.forceForeground()
      self.kioskChannel?.invokeMethod("onNavigationBlocked", arguments: ["reason": "minimize"])
    }
  }

  @objc private func handleWindowDidResignKey(_ notification: Notification) {
    // Do NOT call forceForeground() when MainFlutterWindow resigns key while ARA Assessment
    // is still the active application: internal sheets, NSAlert, NSOpenPanel, and <select>
    // popups temporarily become key window. Stealing key focus back buries modal panels
    // behind MainFlutterWindow and causes AppKit to play NSBeep() on every mouse click!
    guard MainFlutterWindow.isKioskLocked && !MainFlutterWindow.isExitingCleanly && !MainFlutterWindow.isOfficeSessionActive else { return }
    guard !NSApp.isActive && !hasActiveModalOrSheet() else { return }
  }

  func forceForeground() {
    guard !hasActiveModalOrSheet() else { return }
    self.level = .normal
    NSApp.activate(ignoringOtherApps: true)
    self.makeKeyAndOrderFront(nil)
    restoreWebViewFirstResponderIfNeeded()
  }

  private func evaluateOfficeSessionWindowLevel() {
    self.level = .normal
    if !MainFlutterWindow.isOfficeSessionActive && MainFlutterWindow.isKioskLocked {
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

  override func noResponder(for eventSelector: Selector) {
    // Suppress default AppKit NSBeep() when an unhandled key/mouse selector reaches the window root
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

// MARK: - Unconditional WKWebView SSL / TLS Certificate Auto-Trust & Safe Sheet Dialogs (macOS)

extension InAppWebView {
  private static var hasInstalledSslBypass = false

  static func installAraSslCertificateBypass() {
    guard !hasInstalledSslBypass else { return }
    hasInstalledSslBypass = true

    swizzleInstanceMethod(
      targetClass: InAppWebView.self,
      original: #selector(WKNavigationDelegate.webView(_:didReceive:completionHandler:)),
      replacement: #selector(InAppWebView.ara_webView(_:didReceive:completionHandler:))
    )

    swizzleInstanceMethod(
      targetClass: InAppWebView.self,
      original: #selector(WKNavigationDelegate.webView(_:authenticationChallenge:shouldAllowDeprecatedTLS:)),
      replacement: #selector(InAppWebView.ara_webView(_:authenticationChallenge:shouldAllowDeprecatedTLS:))
    )

    if #available(macOS 10.12, *) {
      swizzleInstanceMethod(
        targetClass: InAppWebView.self,
        original: #selector(WKUIDelegate.webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:)),
        replacement: #selector(InAppWebView.ara_webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:))
      )
    }
  }

  private static func swizzleInstanceMethod(targetClass: AnyClass, original: Selector, replacement: Selector) {
    guard
      let originalMethod = class_getInstanceMethod(targetClass, original),
      let replacementMethod = class_getInstanceMethod(targetClass, replacement)
    else {
      return
    }
    let didAdd = class_addMethod(
      targetClass,
      original,
      method_getImplementation(replacementMethod),
      method_getTypeEncoding(replacementMethod)
    )
    if didAdd {
      class_replaceMethod(
        targetClass,
        replacement,
        method_getImplementation(originalMethod),
        method_getTypeEncoding(originalMethod)
      )
    } else {
      method_exchangeImplementations(originalMethod, replacementMethod)
    }
  }

  @objc func ara_webView(
    _ webView: WKWebView,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      guard let serverTrust = challenge.protectionSpace.serverTrust else {
        completionHandler(.performDefaultHandling, nil)
        return
      }

      // 1. Disable blocking network AIA / OCSP fetches so SecTrust never hangs or times out
      SecTrustSetNetworkFetchAllowed(serverTrust, false)

      // 2. Trust the server's presented certificate chain as anchor certificates
      if #available(macOS 12.0, *) {
        if let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate], !certChain.isEmpty {
          SecTrustSetAnchorCertificates(serverTrust, certChain as CFArray)
          SecTrustSetAnchorCertificatesOnly(serverTrust, false)
        }
      } else if let leafCert = SecTrustGetCertificateAtIndex(serverTrust, 0) {
        SecTrustSetAnchorCertificates(serverTrust, [leafCert] as CFArray)
        SecTrustSetAnchorCertificatesOnly(serverTrust, false)
      }

      // 3. Evaluate synchronously on the local trust object (< 0.05ms, zero network I/O)
      _ = SecTrustEvaluateWithError(serverTrust, nil)

      // 4. Stamp trust exceptions onto serverTrust so com.apple.WebKit.Networking accepts it across IPC
      if let exceptions = SecTrustCopyExceptions(serverTrust) {
        SecTrustSetExceptions(serverTrust, exceptions)
      }

      let credential = URLCredential(trust: serverTrust)
      if Thread.isMainThread {
        completionHandler(.useCredential, credential)
      } else {
        DispatchQueue.main.async {
          completionHandler(.useCredential, credential)
        }
      }
      return
    }

    // For non-ServerTrust challenges (e.g. HTTP Basic Auth), forward to original implementation
    self.ara_webView(webView, didReceive: challenge, completionHandler: completionHandler)
  }

  @objc func ara_webView(
    _ webView: WKWebView,
    authenticationChallenge challenge: URLAuthenticationChallenge,
    shouldAllowDeprecatedTLS decisionHandler: @escaping (Bool) -> Void
  ) {
    if Thread.isMainThread {
      decisionHandler(true)
    } else {
      DispatchQueue.main.async {
        decisionHandler(true)
      }
    }
  }

  @available(macOS 10.12, *)
  @objc func ara_webView(
    _ webView: WKWebView,
    runOpenPanelWith parameters: WKOpenPanelParameters,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping ([URL]?) -> Void
  ) {
    let openPanel = NSOpenPanel()
    openPanel.canChooseFiles = true
    if #available(macOS 10.13.4, *) {
      openPanel.canChooseDirectories = parameters.allowsDirectories
    }
    openPanel.allowsMultipleSelection = parameters.allowsMultipleSelection
    openPanel.level = .modalPanel

    if let parentWindow = webView.window ?? NSApp.mainWindow ?? NSApp.keyWindow {
      openPanel.beginSheetModal(for: parentWindow) { result in
        if result == .OK {
          completionHandler(openPanel.urls)
        } else {
          completionHandler(nil)
        }
      }
    } else {
      openPanel.begin { result in
        if result == .OK {
          completionHandler(openPanel.urls)
        } else {
          completionHandler(nil)
        }
      }
    }
  }
}
