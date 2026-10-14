import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AraMobileKioskPlugin") {
      AraMobileKioskPlugin.register(with: registrar)
    }
  }
}

/// iOS side of the `ara_desktop/mobile_kiosk` channel (Android lives in MainActivity.kt).
///
/// Kept in AppDelegate.swift so it is compiled by the existing Runner target without
/// editing project.pbxproj.
final class AraMobileKioskPlugin: NSObject, FlutterPlugin, UIDocumentInteractionControllerDelegate {
  /// Strong reference: UIDocumentInteractionController must stay alive while its menu/preview is shown.
  private var documentController: UIDocumentInteractionController?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "ara_desktop/mobile_kiosk", binaryMessenger: registrar.messenger())
    let instance = AraMobileKioskPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "openDocument":
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Document path is null", details: nil))
        return
      }
      openDocument(path: path, result: result)
    case "setFlagSecure":
      // Android-only (FLAG_SECURE). iOS has no equivalent API; acknowledge as a no-op.
      result(true)
    case "launchPackage", "isPackageInstalled":
      // Android package-manager concepts; iOS uses URL schemes from Dart instead.
      result(false)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

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

  /// Top-most view controller of the key window (UIScene-aware).
  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap { $0.windows }
    let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
