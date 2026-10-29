import Flutter
import ObjectiveC.runtime
import Security
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    FlutterViewController.installAraKioskGestureOverrides()
    WKWebView.installAraSslCertificateBypass()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    WKWebView.installAraSslCertificateBypass()
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AraMobileKioskPlugin") {
      AraMobileKioskPlugin.register(with: registrar)
    }
  }
}

// MARK: - Unconditional WKWebView SSL / TLS Certificate Auto-Trust (iOS)

extension WKWebView {
  private static var hasInstalledSslBypass = false

  static func installAraSslCertificateBypass() {
    guard !hasInstalledSslBypass else { return }
    guard let targetClass = NSClassFromString("flutter_inappwebview_ios.InAppWebView") else {
      return
    }
    hasInstalledSslBypass = true

    swizzleWebViewMethod(
      targetClass: targetClass,
      original: #selector(WKNavigationDelegate.webView(_:didReceive:completionHandler:)),
      replacement: #selector(WKWebView.ara_webView(_:didReceive:completionHandler:))
    )

    swizzleWebViewMethod(
      targetClass: targetClass,
      original: #selector(WKNavigationDelegate.webView(_:authenticationChallenge:shouldAllowDeprecatedTLS:)),
      replacement: #selector(WKWebView.ara_webView(_:authenticationChallenge:shouldAllowDeprecatedTLS:))
    )
  }

  private static func swizzleWebViewMethod(targetClass: AnyClass, original: Selector, replacement: Selector) {
    guard
      let originalMethod = class_getInstanceMethod(targetClass, original),
      let replacementMethod = class_getInstanceMethod(WKWebView.self, replacement)
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

      SecTrustSetNetworkFetchAllowed(serverTrust, false)

      if #available(iOS 15.0, *) {
        if let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate], !certChain.isEmpty {
          SecTrustSetAnchorCertificates(serverTrust, certChain as CFArray)
          SecTrustSetAnchorCertificatesOnly(serverTrust, false)
        }
      } else if let leafCert = SecTrustGetCertificateAtIndex(serverTrust, 0) {
        SecTrustSetAnchorCertificates(serverTrust, [leafCert] as CFArray)
        SecTrustSetAnchorCertificatesOnly(serverTrust, false)
      }

      _ = SecTrustEvaluateWithError(serverTrust, nil)

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
}

// MARK: - FlutterViewController Kiosk System Gesture & Home Indicator Overrides

extension FlutterViewController {
  private static var hasSwizzledKioskGetters = false

  static func installAraKioskGestureOverrides() {
    guard !hasSwizzledKioskGetters else { return }
    hasSwizzledKioskGetters = true

    swizzleInstanceMethod(
      original: #selector(getter: UIViewController.preferredScreenEdgesDeferringSystemGestures),
      replacement: #selector(FlutterViewController.ara_preferredScreenEdgesDeferringSystemGestures)
    )
    swizzleInstanceMethod(
      original: #selector(getter: UIViewController.prefersHomeIndicatorAutoHidden),
      replacement: #selector(FlutterViewController.ara_prefersHomeIndicatorAutoHidden)
    )
    swizzleInstanceMethod(
      original: #selector(getter: UIViewController.prefersStatusBarHidden),
      replacement: #selector(FlutterViewController.ara_prefersStatusBarHidden)
    )
  }

  private static func swizzleInstanceMethod(original: Selector, replacement: Selector) {
    guard
      let originalMethod = class_getInstanceMethod(FlutterViewController.self, original),
      let replacementMethod = class_getInstanceMethod(FlutterViewController.self, replacement)
    else {
      return
    }
    let didAdd = class_addMethod(
      FlutterViewController.self,
      original,
      method_getImplementation(replacementMethod),
      method_getTypeEncoding(replacementMethod)
    )
    if didAdd {
      class_replaceMethod(
        FlutterViewController.self,
        replacement,
        method_getImplementation(originalMethod),
        method_getTypeEncoding(originalMethod)
      )
    } else {
      method_exchangeImplementations(originalMethod, replacementMethod)
    }
  }

  @objc func ara_preferredScreenEdgesDeferringSystemGestures() -> UIRectEdge {
    return AraMobileKioskPlugin.isKioskLocked ? .all : []
  }

  @objc func ara_prefersHomeIndicatorAutoHidden() -> Bool {
    return AraMobileKioskPlugin.isKioskLocked
  }

  @objc func ara_prefersStatusBarHidden() -> Bool {
    return AraMobileKioskPlugin.isKioskLocked
  }
}

/// iOS side of the `ara_desktop/mobile_kiosk` channel (Android lives in MainActivity.kt).
///
/// Kept in AppDelegate.swift so it is compiled by the existing Runner target without
/// editing project.pbxproj.
final class AraMobileKioskPlugin: NSObject, FlutterPlugin, UIDocumentInteractionControllerDelegate {
  /// Always-On Kiosk Lockdown is enabled by default on iOS from app launch.
  static var isKioskLocked: Bool = true
  static var isFlagSecureEnabled: Bool = true

  private var channel: FlutterMethodChannel?
  private var isOfficeSessionActive: Bool = false
  private var isPermissionRequestInProgress: Bool = false
  private var isExitingCleanly: Bool = false

  /// Strong reference: UIDocumentInteractionController must stay alive while its menu/preview is shown.
  private var documentController: UIDocumentInteractionController?

  /// Overlay view masking app contents during App Switcher transitions or active screen recording.
  private var securityShieldView: UIView?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "ara_desktop/mobile_kiosk", binaryMessenger: registrar.messenger())
    let instance = AraMobileKioskPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    setupLifecycleAndSecurityObservers()
    DispatchQueue.main.async { [weak self] in
      self?.applyKioskLockdownState(lockTask: false)
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "openDocument":
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Document path is null", details: nil))
        return
      }
      openDocument(path: path, result: result)

    case "setKioskLockdown":
      let args = call.arguments as? [String: Any]
      let enabled = args?["enabled"] as? Bool ?? true
      let lockTask = args?["lockTask"] as? Bool ?? false
      AraMobileKioskPlugin.isKioskLocked = enabled
      AraMobileKioskPlugin.isFlagSecureEnabled = enabled
      DispatchQueue.main.async { [weak self] in
        self?.applyKioskLockdownState(lockTask: lockTask)
      }
      result(true)

    case "setFlagSecure":
      let args = call.arguments as? [String: Any]
      let enabled = args?["enabled"] as? Bool ?? false
      AraMobileKioskPlugin.isFlagSecureEnabled = enabled
      DispatchQueue.main.async { [weak self] in
        self?.evaluateScreenCaptureState()
      }
      result(true)

    case "setOfficeSession":
      let args = call.arguments as? [String: Any]
      isOfficeSessionActive = args?["active"] as? Bool ?? false
      result(true)

    case "setPermissionRequestInProgress":
      let args = call.arguments as? [String: Any]
      isPermissionRequestInProgress = args?["active"] as? Bool ?? false
      result(true)

    case "exitApp":
      isExitingCleanly = true
      AraMobileKioskPlugin.isKioskLocked = false
      AraMobileKioskPlugin.isFlagSecureEnabled = false
      DispatchQueue.main.async { [weak self] in
        self?.applyKioskLockdownState(lockTask: false)
        UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
      }
      result(true)

    case "launchPackage", "isPackageInstalled":
      // Android package-manager concepts; iOS uses URL schemes from Dart instead.
      result(false)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Kiosk Lockdown & System Gesture Control

  private func setupLifecycleAndSecurityObservers() {
    let nc = NotificationCenter.default
    nc.addObserver(
      self,
      selector: #selector(handleWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    nc.addObserver(
      self,
      selector: #selector(handleDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    nc.addObserver(
      self,
      selector: #selector(handleDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    nc.addObserver(
      self,
      selector: #selector(handleUserDidTakeScreenshot),
      name: UIApplication.userDidTakeScreenshotNotification,
      object: nil
    )
    nc.addObserver(
      self,
      selector: #selector(handleScreenCapturedDidChange),
      name: UIScreen.capturedDidChangeNotification,
      object: nil
    )
  }

  private func applyKioskLockdownState(lockTask: Bool) {
    let locked = AraMobileKioskPlugin.isKioskLocked
    UIApplication.shared.isIdleTimerDisabled = locked

    if let rootVC = AraMobileKioskPlugin.rootViewController() {
      rootVC.navigationController?.interactivePopGestureRecognizer?.isEnabled = !locked
      rootVC.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
      rootVC.setNeedsUpdateOfHomeIndicatorAutoHidden()
      rootVC.setNeedsStatusBarAppearanceUpdate()
    }

    if lockTask || UIAccessibility.isGuidedAccessEnabled {
      UIAccessibility.requestGuidedAccessSession(enabled: locked) { _ in }
    }

    evaluateScreenCaptureState()
  }

  @objc private func handleWillResignActive() {
    guard AraMobileKioskPlugin.isKioskLocked || AraMobileKioskPlugin.isFlagSecureEnabled else { return }
    if !isOfficeSessionActive && !isPermissionRequestInProgress {
      showSecurityShield(message: "ARA Assessment — Mode Ujian Terkunci")
    }
  }

  @objc private func handleDidEnterBackground() {
    guard AraMobileKioskPlugin.isKioskLocked else { return }
    if !isOfficeSessionActive && !isPermissionRequestInProgress && !isExitingCleanly {
      showSecurityShield(message: "ARA Assessment — Mode Ujian Terkunci")
      notifyNavigationBlocked(reason: "minimize")
    }
  }

  @objc private func handleDidBecomeActive() {
    applyKioskLockdownState(lockTask: false)
    if !(AraMobileKioskPlugin.isFlagSecureEnabled && UIScreen.main.isCaptured) {
      hideSecurityShield()
    }
  }

  @objc private func handleUserDidTakeScreenshot() {
    guard AraMobileKioskPlugin.isKioskLocked || AraMobileKioskPlugin.isFlagSecureEnabled else { return }
    notifyNavigationBlocked(reason: "screenshot")
  }

  @objc private func handleScreenCapturedDidChange() {
    evaluateScreenCaptureState()
  }

  private func evaluateScreenCaptureState() {
    if (AraMobileKioskPlugin.isKioskLocked || AraMobileKioskPlugin.isFlagSecureEnabled) && UIScreen.main.isCaptured {
      showSecurityShield(message: "Perekaman Layar / Screen Mirroring Dilarang Selama Ujian!")
      notifyNavigationBlocked(reason: "screen_capture")
    } else if UIApplication.shared.applicationState == .active {
      hideSecurityShield()
    }
  }

  private func showSecurityShield(message: String) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, let window = AraMobileKioskPlugin.keyWindow() else { return }
      if let existing = self.securityShieldView {
        existing.frame = window.bounds
        if let label = existing.viewWithTag(9901) as? UILabel {
          label.text = message
        }
        window.bringSubviewToFront(existing)
        return
      }

      let shield = UIView(frame: window.bounds)
      shield.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.18, alpha: 1.0)
      shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]

      let label = UILabel()
      label.tag = 9901
      label.text = message
      label.textColor = .white
      label.font = UIFont.boldSystemFont(ofSize: 16)
      label.textAlignment = .center
      label.numberOfLines = 0
      label.translatesAutoresizingMaskIntoConstraints = false
      shield.addSubview(label)

      NSLayoutConstraint.activate([
        label.centerXAnchor.constraint(equalTo: shield.centerXAnchor),
        label.centerYAnchor.constraint(equalTo: shield.centerYAnchor),
        label.leadingAnchor.constraint(greaterThanOrEqualTo: shield.leadingAnchor, constant: 24),
        label.trailingAnchor.constraint(lessThanOrEqualTo: shield.trailingAnchor, constant: -24),
      ])

      window.addSubview(shield)
      window.bringSubviewToFront(shield)
      self.securityShieldView = shield
    }
  }

  private func hideSecurityShield() {
    DispatchQueue.main.async { [weak self] in
      self?.securityShieldView?.removeFromSuperview()
      self?.securityShieldView = nil
    }
  }

  private func notifyNavigationBlocked(reason: String) {
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod("onNavigationBlocked", arguments: ["reason": reason])
    }
  }

  // MARK: - Office Document Presentation

  /// Presents the system "Open in..." sheet so the user can pick Word / Excel / PowerPoint.
  /// Returns "opened" when the sheet is shown, or "preview" when no installed app can open
  /// the file (the document is then shown in an in-app QuickLook preview instead).
  private func openDocument(path: String, result: @escaping FlutterResult) {
    guard FileManager.default.fileExists(atPath: path) else {
      result(FlutterError(code: "OPEN_DOCUMENT_ERROR", message: "File not found: \(path)", details: nil))
      return
    }

    DispatchQueue.main.async {
      guard let presenter = AraMobileKioskPlugin.topViewController() else {
        result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "No view controller to present from", details: nil))
        return
      }

      self.isOfficeSessionActive = true
      let controller = UIDocumentInteractionController(url: URL(fileURLWithPath: path))
      controller.delegate = self
      self.documentController = controller

      // Anchor rect is required for the iPad popover presentation.
      let bounds = presenter.view.bounds
      let anchor = CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)

      if controller.presentOpenInMenu(from: anchor, in: presenter.view, animated: true) {
        result("opened")
      } else if controller.presentPreview(animated: true) {
        result("preview")
      } else {
        result("no_app")
      }
    }
  }

  // MARK: - UIDocumentInteractionControllerDelegate

  func documentInteractionControllerViewControllerForPreview(
    _ controller: UIDocumentInteractionController
  ) -> UIViewController {
    return AraMobileKioskPlugin.topViewController() ?? UIViewController()
  }

  // MARK: - Helpers

  private static func keyWindow() -> UIWindow? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap { $0.windows }
    return windows.first(where: { $0.isKeyWindow }) ?? windows.first
  }

  private static func rootViewController() -> UIViewController? {
    return keyWindow()?.rootViewController
  }

  /// Top-most view controller of the key window (UIScene-aware).
  private static func topViewController() -> UIViewController? {
    var top = rootViewController()
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
