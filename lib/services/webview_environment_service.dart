import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Windows WebView2 startup helper.
///
/// We intentionally use the plugin's DEFAULT WebView2 environment (no custom
/// [WebViewEnvironment]). Creating a custom environment hung ~25s and then failed
/// with E_UNEXPECTED ("Catastrophic failure"), which delayed the first page load
/// by ~48s. The default environment starts instantly; its user-data folder is
/// redirected to `%LOCALAPPDATA%\ARA Assessment\WebView2_v2` via the
/// `WEBVIEW2_USER_DATA_FOLDER` variable set in `windows/runner/main.cpp`.
/// Camera/mic are auto-granted by the native PermissionRequested handler and
/// certificate/autoplay behaviour by InAppWebView settings, so no browser args
/// are required.
///
/// All methods resolve to `null` (= use default environment).
class WebViewEnvironmentService {
  WebViewEnvironmentService._();
  static final WebViewEnvironmentService instance = WebViewEnvironmentService._();

  Future<WebViewEnvironment?>? _pending;

  bool get _isWindows => !kIsWeb && Platform.isWindows;

  /// Ensures the WebView2 runtime exists (fast check; only installs if missing).
  /// Safe to call multiple times; concurrent callers share the same future.
  Future<WebViewEnvironment?> warmUp() {
    if (!_isWindows) return Future<WebViewEnvironment?>.value(null);
    return _pending ??= _ensureRuntimeInstalled().then((_) => null);
  }

  /// Re-runs the runtime check (used by manual refresh after a failure).
  Future<WebViewEnvironment?> retry() {
    if (!_isWindows) return Future<WebViewEnvironment?>.value(null);
    _pending = _ensureRuntimeInstalled().then((_) => null);
    return _pending!;
  }

  Future<void> _ensureRuntimeInstalled() async {
    try {
      final version = await WebViewEnvironment.getAvailableVersion();
      if (version != null && version.trim().isNotEmpty) {
        debugPrint('[WebViewEnv] Detected WebView2 Runtime version: $version (using default environment)');
        return;
      }
    } catch (e) {
      debugPrint('[WebViewEnv] getAvailableVersion check error: $e');
    }

    // Auto-install bundled WebView2 evergreen bootstrapper if missing on participant laptop
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final setupCandidates = [
        '$exeDir\\MicrosoftEdgeWebView2Setup.exe',
        '${Directory.current.path}\\windows\\redist\\MicrosoftEdgeWebView2Setup.exe',
      ];
      for (final setupPath in setupCandidates) {
        if (await File(setupPath).exists()) {
          debugPrint('[WebViewEnv] WebView2 missing; running silent bootstrapper: $setupPath');
          await Process.run(setupPath, ['/silent', '/install']).timeout(const Duration(seconds: 45));
          break;
        }
      }
    } catch (e) {
      debugPrint('[WebViewEnv] WebView2 bootstrapper auto-install error: $e');
    }
  }
}
