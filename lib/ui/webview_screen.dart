import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import '../config/env_config.dart';
import '../services/assessment_detector.dart';
import '../services/kiosk_security_service.dart';
import '../services/office_document_service.dart';
import '../services/office_launcher_service.dart';

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> with WindowListener, WidgetsBindingObserver {
  static const String kHardcodedProductionUrl = 'https://ara-assessment.com/assess';

  InAppWebViewController? _webViewController;
  WebViewEnvironment? _webViewEnvironment;
  bool _isWebViewEnvReady = false;
  int _webViewRebuildKey = 0;
  String? _preferredCameraDeviceId;
  final KioskSecurityService _kioskService = KioskSecurityService();
  final AssessmentDetector _detector = AssessmentDetector();

  bool _isLoading = true;
  double _loadProgress = 0.0;
  bool _hasError = false;
  String _errorMessage = '';
  bool _hasLoadedSuccessfully = false;
  int _autoRetryCount = 0;
  String? _lastRequestedUrl;
  Timer? _loadingWatchdogTimer;
  int _loadingElapsedSeconds = 0;

  final FocusNode _keyboardFocusNode = FocusNode();
  bool _isSupervisorDialogOpen = false;

  bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  bool get _isWindows => !kIsWeb && Platform.isWindows;

  /// Platform-specific mobile user agent (desktop keeps the engine default).
  /// Android: modern Chrome Mobile UA to avoid restrictive `wv` bot filtering.
  /// iOS: Mobile Safari UA (an Android UA on WKWebView makes sites serve Android-only flows).
  String? get _platformUserAgent {
    if (kIsWeb) return null;
    if (Platform.isAndroid) {
      return 'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';
    }
    if (Platform.isIOS) {
      return 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';
    }
    return null;
  }

  static const Set<String> _passThroughSchemes = {'http', 'https', 'about', 'data', 'blob', 'javascript', 'file'};
  static const Set<String> _officeSchemes = {'ms-word', 'ms-excel', 'ms-powerpoint', 'ms-office'};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestInitialPermissions();
    _detector.onSupervisorRequested = _showSupervisorDialog;
    _detector.onDomReady = _handleDomReady;
    _detector.onExternalOrOfficeUrlRequested = _handleJsExternalOrOfficeUrl;
    _kioskService.onRefreshRequested = _handleRefresh;
    _kioskService.onViolationDetected = _handleKioskViolation;
    HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      windowManager.addListener(this);
    }
    unawaited(_initWindowsWebViewEnvironment());
    _startLoadingWatchdog(resetElapsed: true);
  }

  static const String _kWindowsBrowserArgs =
      '--use-fake-ui-for-media-stream '
      '--auto-accept-camera-and-microphone-capture '
      '--ignore-certificate-errors '
      '--allow-running-insecure-content '
      '--autoplay-policy=no-user-gesture-required '
      '--disable-features=msSmartScreenProtection,CalculateNativeWinOcclusion,RendererCodeIntegrity';

  String _buildCameraCompatibilityScript() {
    final preferredJson = jsonEncode(_preferredCameraDeviceId ?? '');
    return '''
(function() {
  if (window.__araCameraCompatInstalled) {
    if ($preferredJson) {
      window.__araPreferredCameraId = $preferredJson;
      try { localStorage.setItem('__araPreferredCameraId', $preferredJson); } catch (_) {}
    }
    return;
  }
  window.__araCameraCompatInstalled = true;

  var initialPref = $preferredJson;
  if (!initialPref) {
    try { initialPref = localStorage.getItem('__araPreferredCameraId') || ''; } catch (_) {}
  }
  window.__araPreferredCameraId = initialPref || '';

  // Ensure Permissions API never reports camera/microphone as pre-denied in WebView
  if (navigator.permissions && typeof navigator.permissions.query === 'function') {
    var origPermQuery = navigator.permissions.query.bind(navigator.permissions);
    navigator.permissions.query = function(desc) {
      if (desc && (desc.name === 'camera' || desc.name === 'microphone')) {
        return origPermQuery(desc).then(function(status) {
          if (status && status.state === 'denied') {
            return { state: 'prompt', onchange: null, addEventListener: function(){}, removeEventListener: function(){} };
          }
          return status;
        }).catch(function() {
          return { state: 'granted', onchange: null, addEventListener: function(){}, removeEventListener: function(){} };
        });
      }
      return origPermQuery(desc);
    };
  }

  if (!navigator.mediaDevices || typeof navigator.mediaDevices.getUserMedia !== 'function') {
    return;
  }

  var origGetUserMedia = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
  var virtualRegex = /obs|virtual|manycam|snap camera|vcam|droidcam|iriun|epoccam|xsplit|splitcam|cyberlink|avatar/i;

  function cloneWithDeviceId(constraints, deviceId, relaxVideo) {
    var next = {};
    if (constraints && typeof constraints === 'object') {
      for (var k in constraints) {
        if (Object.prototype.hasOwnProperty.call(constraints, k)) {
          next[k] = constraints[k];
        }
      }
    }
    if (relaxVideo) {
      next.video = deviceId ? { deviceId: { exact: deviceId } } : true;
    } else if (deviceId) {
      var baseVideo = (constraints && typeof constraints.video === 'object') ? constraints.video : {};
      var merged = {};
      for (var vk in baseVideo) {
        if (Object.prototype.hasOwnProperty.call(baseVideo, vk) && vk !== 'facingMode' && vk !== 'deviceId') {
          merged[vk] = baseVideo[vk];
        }
      }
      merged.deviceId = { exact: deviceId };
      next.video = merged;
    }
    return next;
  }

  navigator.mediaDevices.getUserMedia = async function(constraints) {
    var wantsVideo = Boolean(constraints && constraints.video);
    if (!wantsVideo) {
      return origGetUserMedia(constraints);
    }

    var preferredId = window.__araPreferredCameraId || '';
    if (!preferredId) {
      try { preferredId = localStorage.getItem('__araPreferredCameraId') || ''; } catch (_) {}
    }

    // 1. If participant selected a specific camera via Force Kamera, try it first
    if (preferredId) {
      try {
        return await origGetUserMedia(cloneWithDeviceId(constraints, preferredId, false));
      } catch (_) {
        try {
          return await origGetUserMedia(cloneWithDeviceId(constraints, preferredId, true));
        } catch (_e2) {}
      }
    }

    // 2. Standard portal request
    try {
      return await origGetUserMedia(constraints);
    } catch (primaryErr) {
      console.warn('[ARA Camera Compat] Primary getUserMedia failed, trying fallbacks:', primaryErr && primaryErr.name, primaryErr && primaryErr.message);

      // 3. Relax strict resolution / facingMode constraints (fixes OverconstrainedError on 480p webcams)
      try {
        return await origGetUserMedia(cloneWithDeviceId(constraints, '', true));
      } catch (_) {}

      // 4. Enumerate all videoinput devices and try physical hardware cameras before virtual cameras
      if (typeof navigator.mediaDevices.enumerateDevices === 'function') {
        try {
          var devices = await navigator.mediaDevices.enumerateDevices();
          var cams = devices.filter(function(d) { return d && d.kind === 'videoinput' && d.deviceId; });
          cams.sort(function(a, b) {
            var aVirt = virtualRegex.test(a.label || '') ? 1 : 0;
            var bVirt = virtualRegex.test(b.label || '') ? 1 : 0;
            return aVirt - bVirt;
          });
          for (var i = 0; i < cams.length; i++) {
            try {
              var stream = await origGetUserMedia(cloneWithDeviceId(constraints, cams[i].deviceId, true));
              window.__araPreferredCameraId = cams[i].deviceId;
              return stream;
            } catch (_) {}
          }
        } catch (_) {}
      }

      throw primaryErr;
    }
  };
})();
''';
  }

  Future<void> _ensureWebView2RuntimeInstalled() async {
    if (!_isWindows) return;
    try {
      final version = await WebViewEnvironment.getAvailableVersion();
      if (version != null && version.trim().isNotEmpty) {
        debugPrint('[WebViewScreen] Detected WebView2 Runtime version: $version');
        return;
      }
    } catch (e) {
      debugPrint('[WebViewScreen] getAvailableVersion check error: $e');
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
          debugPrint('[WebViewScreen] WebView2 missing; running silent bootstrapper: $setupPath');
          await Process.run(setupPath, ['/silent', '/install']).timeout(const Duration(seconds: 45));
          break;
        }
      }
    } catch (e) {
      debugPrint('[WebViewScreen] WebView2 bootstrapper auto-install error: $e');
    }
  }

  Future<void> _initWindowsWebViewEnvironment() async {
    if (!_isWindows) {
      if (mounted) {
        setState(() {
          _isWebViewEnvReady = true;
        });
      }
      return;
    }

    // Proactively ensure OS-level Windows webcam & mic permissions are Allow on every app launch
    unawaited(_kioskService.forceWindowsCameraAccess());

    await _ensureWebView2RuntimeInstalled();

    final localAppData = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    final primaryFolder = '$localAppData\\ARA Assessment\\WebView2_v2';
    final fallbackFolder = '$localAppData\\ARA Assessment\\WebView2_Session_$pid';

    for (final folder in [primaryFolder, fallbackFolder]) {
      try {
        await Directory(folder).create(recursive: true);
        _webViewEnvironment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(
            userDataFolder: folder,
            additionalBrowserArguments: _kWindowsBrowserArgs,
          ),
        ).timeout(const Duration(seconds: 25));
        debugPrint('[WebViewScreen] WebViewEnvironment created at: $folder');
        break;
      } catch (e) {
        debugPrint('[WebViewScreen] WebViewEnvironment failed at $folder ($e)');
        _webViewEnvironment = null;
      }
    }

    if (mounted) {
      setState(() {
        _isWebViewEnvReady = true;
      });
    }
  }

  @override
  void dispose() {
    _stopLoadingWatchdog();
    WidgetsBinding.instance.removeObserver(this);
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      windowManager.removeListener(this);
    }
    _kioskService.onRefreshRequested = null;
    _kioskService.onViolationDetected = null;
    HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    _detector.onSupervisorRequested = null;
    _detector.onDomReady = null;
    _detector.onExternalOrOfficeUrlRequested = null;
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  void _handleDomReady(String url) {
    if (!mounted) return;
    final cleanUrl = url.trim();
    final isValid = cleanUrl.isNotEmpty &&
        cleanUrl != 'about:blank' &&
        (cleanUrl.startsWith('http://') || cleanUrl.startsWith('https://'));
    if (isValid) {
      _lastRequestedUrl = cleanUrl;
      _detector.evaluateUrl(cleanUrl);
    }
    if (_isLoading || _loadProgress < 1.0) {
      setState(() {
        _isLoading = false;
        _loadProgress = 1.0;
        if (isValid && !_hasError) {
          _hasLoadedSuccessfully = true;
          _autoRetryCount = 0;
        }
      });
    }
    _stopLoadingWatchdog();
  }

  void _handleJsExternalOrOfficeUrl(String urlStr) {
    final uri = Uri.tryParse(urlStr.trim());
    if (uri == null) return;
    final scheme = uri.scheme.toLowerCase();
    if (_officeSchemes.contains(scheme)) {
      unawaited(_launchOfficeScheme(uri));
      return;
    }
    if ((scheme == 'http' || scheme == 'https') && OfficeDocumentService.isOfficeDocumentUrl(uri)) {
      unawaited(_openPortalDocument(uri));
    }
  }

  String get _activeTargetUrl {
    if (!kReleaseMode && EnvConfig().isLocal) {
      return EnvConfig().localUrl;
    }
    return kHardcodedProductionUrl;
  }

  void _startLoadingWatchdog({bool resetElapsed = false}) {
    if (resetElapsed || _loadingWatchdogTimer == null || !_loadingWatchdogTimer!.isActive) {
      _loadingWatchdogTimer?.cancel();
      if (resetElapsed) {
        _loadingElapsedSeconds = 0;
      }
      _loadingWatchdogTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
        if (!mounted) {
          timer.cancel();
          return;
        }
        if (!_isLoading) {
          timer.cancel();
          return;
        }

        setState(() {
          _loadingElapsedSeconds++;
        });

        final controller = _webViewController;
        if (controller == null) {
          // If native WebView failed to attach within 12s on a slow laptop, rebuild it once automatically
          if (_loadingElapsedSeconds == 12 && _autoRetryCount < 1) {
            _autoRetryCount++;
            debugPrint('[WebViewScreen] WebViewController still null at 12s; triggering automatic WebView rebuild...');
            setState(() {
              _webViewRebuildKey++;
            });
            return;
          }
          // Never drop to a blank #2B2B2B screen; if still null after 28s, show actionable recovery overlay
          if (_loadingElapsedSeconds >= 28) {
            timer.cancel();
            setState(() {
              _isLoading = false;
              _hasError = true;
              _errorMessage =
                  'Komponen tampilan WebView membutuhkan waktu lebih lama untuk dimuat di perangkat ini. '
                  'Silakan klik "Coba Lagi" atau tombol "Refresh" di pojok kiri atas.';
            });
          }
          return;
        }

        // Poll actual DOM readiness every 1 second without aborting in-flight navigations
        try {
          final currentUri = await controller.getUrl();
          final currentUrlStr = currentUri?.toString().trim() ?? '';
          final isValidUrl = currentUrlStr.isNotEmpty &&
              currentUrlStr != 'about:blank' &&
              (currentUrlStr.startsWith('http://') || currentUrlStr.startsWith('https://'));

          if (isValidUrl) {
            final readyStateObj = await controller.evaluateJavascript(source: 'document.readyState');
            final readyState = (readyStateObj?.toString() ?? '').replaceAll('"', '').trim().toLowerCase();
            if (readyState == 'interactive' || readyState == 'complete') {
              debugPrint('[WebViewScreen] Watchdog confirmed DOM readyState=$readyState for $currentUrlStr; dismissing overlay');
              _handleDomReady(currentUrlStr);
              return;
            }
          } else if (_loadingElapsedSeconds == 8) {
            final targetUrl = _activeTargetUrl;
            debugPrint('[WebViewScreen] Watchdog noticed empty/about:blank at 8s; forcing loadUrl($targetUrl)');
            unawaited(controller.loadUrl(urlRequest: URLRequest(url: WebUri(targetUrl))));
          }
        } catch (e) {
          debugPrint('[WebViewScreen] Watchdog poll error: $e');
        }

        // Only dismiss overlay automatically if a page has already loaded; otherwise wait up to 25s
        if (_hasLoadedSuccessfully && _loadingElapsedSeconds >= 6) {
          timer.cancel();
          setState(() {
            _isLoading = false;
            _loadProgress = 1.0;
          });
        } else if (!_hasLoadedSuccessfully && _loadingElapsedSeconds >= 25) {
          timer.cancel();
          setState(() {
            _isLoading = false;
            _hasError = true;
            _errorMessage =
                'Waktu pemuatan halaman habis. Pastikan koneksi internet Anda stabil lalu klik "Coba Lagi".';
          });
        }
      });
    }
  }

  void _stopLoadingWatchdog() {
    _loadingWatchdogTimer?.cancel();
    _loadingWatchdogTimer = null;
  }

  Future<void> _handleKioskViolation(
    String violationType,
    String violationLabel,
    String description,
    String source,
  ) async {
    debugPrint('[WebViewScreen] Recording violation: $violationType ($violationLabel) via $source');

    // 1. Report via InAppWebView JS bridge (uses active session cookies & updates live badge on Exam/Take)
    final controller = _webViewController;
    if (controller != null) {
      final jsCall =
          'if (typeof window.recordAraDesktopViolation === "function") { '
          'window.recordAraDesktopViolation(${jsonEncode(violationType)}, ${jsonEncode(violationLabel)}, ${jsonEncode(description)}, ${jsonEncode(source)}); '
          '}';
      unawaited(
        controller.evaluateJavascript(source: jsCall).catchError((Object e) {
          debugPrint('[WebViewScreen] JS violation bridge error: $e');
          return null;
        }),
      );
    }

    // 2. Also send direct native Dart HTTP POST fallback (in case WebView JS is suspended while app is paused/minimized)
    if (_kioskService.isDevMode && !EnvConfig().recordViolationsInDev) {
      debugPrint('[WebViewScreen] [DEV MODE] Direct HTTP violation POST skipped in dev mode.');
      return;
    }

    final ctx = _detector.lastExamContext;
    final baseUrl = (ctx['baseUrl'] ?? '').trim().replaceAll(RegExp(r'/$'), '');
    final userID = (ctx['userID'] ?? '').trim();
    if (baseUrl.isEmpty || userID.isEmpty) {
      return;
    }

    try {
      final endpointUri = Uri.parse('$baseUrl/Violation/record');
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      final req = await client.postUrl(endpointUri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
      final payload = jsonEncode({
        'userID': userID,
        'examID': ctx['examID'] ?? '',
        'classID': ctx['classID'] ?? '',
        'responseID': ctx['responseID'] ?? '',
        'violation_type': violationType,
        'violation_label': violationLabel,
        'description': description,
        'source': source,
        'platform': kIsWeb ? 'web' : '${Platform.operatingSystem} (${Platform.operatingSystemVersion})',
      });
      req.add(utf8.encode(payload));
      final resp = await req.close();
      await resp.drain<void>();
      client.close(force: false);
    } catch (e) {
      debugPrint('[WebViewScreen] Direct HTTP violation POST failed: $e');
    }
  }

  Future<void> _reloadOrLoadTargetUrl({bool forceLoadUrl = false}) async {
    if (!mounted) return;
    final hadError = _hasError;
    setState(() {
      _hasError = false;
      _errorMessage = '';
      _isLoading = true;
      _loadProgress = 0.0;
    });
    _startLoadingWatchdog(resetElapsed: true);

    final controller = _webViewController;
    if (controller == null) {
      debugPrint('[WebViewScreen] Controller is null during reload; rebuilding InAppWebView instance...');
      if (_isWindows && _webViewEnvironment == null) {
        await _initWindowsWebViewEnvironment();
      }
      if (mounted) {
        setState(() {
          _webViewRebuildKey++;
        });
      }
      return;
    }

    final fallbackUrl = _activeTargetUrl;
    try {
      final currentUri = await controller.getUrl();
      final currentUrlStr = currentUri?.toString().trim() ?? '';
      final hasCommittedUrl = currentUrlStr.isNotEmpty &&
          currentUrlStr != 'about:blank' &&
          (currentUrlStr.startsWith('http://') || currentUrlStr.startsWith('https://'));

      final lastTarget = (_lastRequestedUrl ?? '').trim();
      final hasLastTarget = lastTarget.isNotEmpty &&
          lastTarget != 'about:blank' &&
          (lastTarget.startsWith('http://') || lastTarget.startsWith('https://'));

      if (forceLoadUrl || hadError || !_hasLoadedSuccessfully || !hasCommittedUrl) {
        final targetToLoad = hasLastTarget
            ? lastTarget
            : (hasCommittedUrl ? currentUrlStr : fallbackUrl);
        debugPrint('[WebViewScreen] Loading URL directly: $targetToLoad');
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(targetToLoad)),
        );
      } else {
        debugPrint('[WebViewScreen] Reloading current committed page: $currentUrlStr');
        await controller.reload();
      }
    } catch (e) {
      final targetToLoad = (_lastRequestedUrl != null && _lastRequestedUrl!.isNotEmpty)
          ? _lastRequestedUrl!
          : fallbackUrl;
      debugPrint('[WebViewScreen] Reload failed ($e), falling back to loadUrl($targetToLoad)');
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(targetToLoad)),
      );
    }
  }

  void _handleRefresh() {
    _autoRetryCount = 0;
    unawaited(_reloadOrLoadTargetUrl(forceLoadUrl: _hasError || !_hasLoadedSuccessfully));
  }

  Future<void> _switchTargetServer(AppTargetMode newMode) async {
    if (EnvConfig().targetMode == newMode) return;
    _autoRetryCount = 0;
    _hasLoadedSuccessfully = false;
    setState(() {
      EnvConfig().targetMode = newMode;
      _lastRequestedUrl = EnvConfig().currentUrl;
      _isLoading = true;
      _loadProgress = 0.0;
      _hasError = false;
      _errorMessage = '';
    });
    _startLoadingWatchdog();
    final targetUrl = EnvConfig().currentUrl;
    debugPrint('[WebViewScreen] Switching target server to ${newMode.name.toUpperCase()}: $targetUrl');
    await _webViewController?.loadUrl(
      urlRequest: URLRequest(url: WebUri(targetUrl)),
    );

    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                newMode == AppTargetMode.local ? Icons.computer : Icons.cloud_done,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Server: ${newMode == AppTargetMode.local ? "LOCAL (localhost)" : "PRODUCTION (ara-assessment.com)"}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          backgroundColor: newMode == AppTargetMode.local ? Colors.blue.shade900 : Colors.teal.shade900,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _kioskService.handleAppLifecycleChange(state);
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() {});
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() {});
  }

  bool _handleGlobalKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      // Refresh hotkeys: F5, Ctrl+R, or Cmd+R (macOS)
      if (event.logicalKey == LogicalKeyboardKey.f5 ||
          ((HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed) &&
              event.logicalKey == LogicalKeyboardKey.keyR)) {
        _handleRefresh();
        return true;
      }

      // Dev exit hotkeys: Escape or Ctrl+Q
      if (_kioskService.isDevMode) {
        if (event.logicalKey == LogicalKeyboardKey.escape ||
            (HardwareKeyboard.instance.isControlPressed && event.logicalKey == LogicalKeyboardKey.keyQ)) {
          _kioskService.exitApp();
          return true;
        }

        // Quick toggle server mode between Local and Production (Ctrl + Shift + L)
        if (HardwareKeyboard.instance.isControlPressed &&
            HardwareKeyboard.instance.isShiftPressed &&
            event.logicalKey == LogicalKeyboardKey.keyL) {
          final nextMode = EnvConfig().isLocal ? AppTargetMode.production : AppTargetMode.local;
          _switchTargetServer(nextMode);
          return true;
        }

        // Quick toggle Dev Mode (Ctrl + Shift + D)
        if (HardwareKeyboard.instance.isControlPressed &&
            HardwareKeyboard.instance.isShiftPressed &&
            event.logicalKey == LogicalKeyboardKey.keyD) {
          setState(() {
            final nextDev = !_kioskService.isDevMode;
            _kioskService.isDevMode = nextDev;
            EnvConfig().isDevMode = nextDev;
          });
          return true;
        }
      }
      // Supervisor dialog hotkeys: Ctrl+Shift+F12, Alt+F12, or F12 in dev mode
      if (event.logicalKey == LogicalKeyboardKey.f12 &&
          (HardwareKeyboard.instance.isControlPressed ||
           HardwareKeyboard.instance.isAltPressed ||
           _kioskService.isDevMode)) {
        _showSupervisorDialog();
        return true;
      }
    }
    return false;
  }

  Future<void> _requestInitialPermissions() async {
    // permission_handler is only registered on Android and iOS; on macOS,
    // WKWebView + Info.plist (NSCameraUsageDescription / NSMicrophoneUsageDescription)
    // + onPermissionRequest handle camera and microphone access natively.
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      await _kioskService.setPermissionRequestInProgress(true);
      try {
        final cameraStatus = await Permission.camera.request();
        final micStatus = await Permission.microphone.request();
        debugPrint('[Permissions] Camera: $cameraStatus, Mic: $micStatus');
      } catch (e) {
        debugPrint('[Permissions] Error requesting hardware permissions: $e');
      } finally {
        await _kioskService.setPermissionRequestInProgress(false);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Mobile: Office documents & external links opened from the portal
  // ---------------------------------------------------------------------------

  void _showOfficeResult(OfficeLaunchResult res) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(res.message),
        backgroundColor: res.success
            ? Colors.green.shade800
            : (res.openedStore ? Colors.orange.shade800 : Colors.red.shade800),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<NavigationActionPolicy> _handleNavigation(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final uri = Uri.tryParse(action.request.url?.toString() ?? '');
    if (uri == null) return NavigationActionPolicy.ALLOW;
    final scheme = uri.scheme.toLowerCase();

    if (scheme == 'http' || scheme == 'https') {
      // Main-frame links to .doc/.docx/.xls/.xlsx/.ppt/.pptx -> open in the Office app.
      // Sub-frames are left alone so embedded viewers keep working.
      if (action.isForMainFrame && OfficeDocumentService.isOfficeDocumentUrl(uri)) {
        unawaited(_openPortalDocument(uri));
        return NavigationActionPolicy.CANCEL;
      }
      return NavigationActionPolicy.ALLOW;
    }

    if (_passThroughSchemes.contains(scheme)) return NavigationActionPolicy.ALLOW;

    if (_officeSchemes.contains(scheme)) {
      unawaited(_launchOfficeScheme(uri));
      return NavigationActionPolicy.CANCEL;
    }

    // Other external schemes (tel:, mailto:, intent:, ...): never render an error page;
    // only allowed to leave the app outside of an exam.
    if (_kioskService.currentMode == AssessmentMode.normal) {
      unawaited(
        launchUrl(uri, mode: LaunchMode.externalApplication).catchError((Object e) {
          debugPrint('[InAppWebView] Cannot open external link $uri: $e');
          return false;
        }),
      );
    } else {
      _showOfficeResult(const OfficeLaunchResult(
        success: false,
        message: 'Membuka aplikasi lain diblokir selama ujian.',
      ));
    }
    return NavigationActionPolicy.CANCEL;
  }

  // ---------------------------------------------------------------------------
  // In-App JavaScript Dialogs (alert / confirm / prompt) & Popup Windows
  // Prevents macOS WKWebView from calling blocking NSAlert().runModal() which
  // gets buried behind Kiosk windows and causes NSBeep() on every mouse click.
  // ---------------------------------------------------------------------------

  Future<JsAlertResponse?> _handleJsAlert(
    InAppWebViewController controller,
    JsAlertRequest request,
  ) async {
    final message = (request.message ?? '').trim();
    debugPrint('[InAppWebView] JS Alert: $message');
    if (!mounted) {
      return JsAlertResponse(
        handledByClient: true,
        action: JsAlertResponseAction.CONFIRM,
      );
    }
    try {
      await showDialog<void>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E2E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: const Row(
            children: [
              Icon(Icons.info_outline_rounded, color: Color(0xFF00AEF0), size: 22),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Informasi Portal',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Text(
              message.isNotEmpty ? message : 'Notifikasi dari halaman ujian.',
              style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.45),
            ),
          ),
          actions: [
            ElevatedButton(
              autofocus: true,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00AEF0),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
    } catch (e) {
      debugPrint('[InAppWebView] Error showing JS Alert dialog: $e');
    }
    return JsAlertResponse(
      handledByClient: true,
      action: JsAlertResponseAction.CONFIRM,
    );
  }

  Future<JsConfirmResponse?> _handleJsConfirm(
    InAppWebViewController controller,
    JsConfirmRequest request,
  ) async {
    final message = (request.message ?? '').trim();
    debugPrint('[InAppWebView] JS Confirm: $message');
    if (!mounted) {
      return JsConfirmResponse(
        handledByClient: true,
        action: JsConfirmResponseAction.CONFIRM,
      );
    }
    bool confirmed = false;
    try {
      final res = await showDialog<bool>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E2E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: const Row(
            children: [
              Icon(Icons.help_outline_rounded, color: Colors.amberAccent, size: 22),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Konfirmasi',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Text(
              message.isNotEmpty ? message : 'Apakah Anda yakin ingin melanjutkan?',
              style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.45),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Batal', style: TextStyle(color: Colors.white70)),
            ),
            ElevatedButton(
              autofocus: true,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00AEF0),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('OK', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
      confirmed = res ?? false;
    } catch (e) {
      debugPrint('[InAppWebView] Error showing JS Confirm dialog: $e');
    }
    return JsConfirmResponse(
      handledByClient: true,
      action: confirmed ? JsConfirmResponseAction.CONFIRM : JsConfirmResponseAction.CANCEL,
    );
  }

  Future<JsPromptResponse?> _handleJsPrompt(
    InAppWebViewController controller,
    JsPromptRequest request,
  ) async {
    final message = (request.message ?? '').trim();
    final defaultValue = request.defaultValue ?? '';
    debugPrint('[InAppWebView] JS Prompt: $message');
    if (!mounted) {
      return JsPromptResponse(
        handledByClient: true,
        action: JsPromptResponseAction.CANCEL,
      );
    }
    final textController = TextEditingController(text: defaultValue);
    String? submittedValue;
    try {
      submittedValue = await showDialog<String>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E2E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Text(
            message.isNotEmpty ? message : 'Masukkan Input',
            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: TextField(
              controller: textController,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.white10,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onSubmitted: (val) => Navigator.of(ctx).pop(val),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Batal', style: TextStyle(color: Colors.white70)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00AEF0),
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(ctx).pop(textController.text),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      debugPrint('[InAppWebView] Error showing JS Prompt dialog: $e');
    } finally {
      textController.dispose();
    }
    return JsPromptResponse(
      handledByClient: true,
      action: submittedValue != null ? JsPromptResponseAction.CONFIRM : JsPromptResponseAction.CANCEL,
      value: submittedValue,
    );
  }

  Future<bool?> _handleCreateWindow(
    InAppWebViewController controller,
    CreateWindowAction createWindowAction,
  ) async {
    final targetUrl = createWindowAction.request.url;
    if (targetUrl != null) {
      final uri = Uri.tryParse(targetUrl.toString());
      if (uri != null && OfficeDocumentService.isOfficeDocumentUrl(uri)) {
        unawaited(_openPortalDocument(uri));
        return false;
      }
    }

    if (!mounted) return false;

    // Open genuine in-app popup window so window.open(), target="_blank", and window.close()
    // work universally just like a standard desktop/mobile browser.
    unawaited(
      showDialog<void>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: true,
        builder: (ctx) => Dialog(
          backgroundColor: const Color(0xFF1E1E2E),
          insetPadding: const EdgeInsets.all(24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 960,
            height: 680,
            child: Column(
              children: [
                Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  color: const Color(0xFF2B2B2B),
                  child: Row(
                    children: [
                      const Icon(Icons.open_in_new_rounded, color: Color(0xFF00AEF0), size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          targetUrl?.toString().isNotEmpty == true
                              ? targetUrl.toString()
                              : 'Jendela Portal ARA Assessment',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 18),
                        tooltip: 'Tutup Jendela',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: InAppWebView(
                    windowId: createWindowAction.windowId,
                    initialUrlRequest: targetUrl != null ? createWindowAction.request : null,
                    initialUserScripts: UnmodifiableListView<UserScript>([
                      UserScript(
                        source: _buildCameraCompatibilityScript(),
                        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                      ),
                    ]),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      allowsInlineMediaPlayback: true,
                      mediaPlaybackRequiresUserGesture: false,
                      domStorageEnabled: true,
                      databaseEnabled: true,
                      thirdPartyCookiesEnabled: true,
                      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                      javaScriptCanOpenWindowsAutomatically: true,
                      supportMultipleWindows: true,
                      useOnDownloadStart: true,
                      userAgent: _platformUserAgent,
                    ),
                    onJsAlert: _handleJsAlert,
                    onJsConfirm: _handleJsConfirm,
                    onJsPrompt: _handleJsPrompt,
                    onDownloadStartRequest: _handleDownload,
                    onPermissionRequest: (ctrl, request) async {
                      return PermissionResponse(
                        resources: request.resources,
                        action: PermissionResponseAction.GRANT,
                      );
                    },
                    onCloseWindow: (ctrl) {
                      if (Navigator.of(ctx, rootNavigator: true).canPop()) {
                        Navigator.of(ctx, rootNavigator: true).pop();
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return true;
  }

  Future<void> _launchOfficeScheme(Uri uri) async {
    final scheme = uri.scheme.toLowerCase();
    final app = scheme == 'ms-excel'
        ? OfficeAppConfig.excel
        : (scheme == 'ms-powerpoint' ? OfficeAppConfig.powerPoint : OfficeAppConfig.word);

    _kioskService.markOfficeSessionStarted();
    var launched = false;
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[InAppWebView] Office scheme launch failed for $uri: $e');
    }
    if (!launched) {
      _showOfficeResult(await OfficeLauncherService().openStoreFor(app));
    }
  }

  Future<void> _handleDownload(
    InAppWebViewController controller,
    DownloadStartRequest request,
  ) async {
    debugPrint('[InAppWebView] Download requested: ${request.url} (${request.mimeType}, ${request.suggestedFilename})');
    final uri = Uri.tryParse(request.url.toString());
    if (uri == null) return;
    await _openPortalDocument(
      uri,
      suggestedFileName: request.suggestedFilename,
      mimeType: request.mimeType,
      userAgent: request.userAgent,
    );
  }

  Future<void> _openPortalDocument(
    Uri uri, {
    String? suggestedFileName,
    String? mimeType,
    String? userAgent,
  }) async {
    final service = OfficeDocumentService();
    if (service.isBusy) {
      _showOfficeResult(const OfficeLaunchResult(
        success: false,
        message: 'Dokumen lain sedang diunduh, mohon tunggu sebentar...',
      ));
      return;
    }

    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                ),
                SizedBox(width: 12),
                Expanded(child: Text('Mengunduh & membuka dokumen...')),
              ],
            ),
            backgroundColor: Color(0xFF1E1E2E),
            duration: Duration(minutes: 2),
          ),
        );
    }

    final res = await service.downloadAndOpen(
      url: uri,
      suggestedFileName: suggestedFileName,
      mimeType: mimeType,
      userAgent: (userAgent != null && userAgent.isNotEmpty) ? userAgent : _platformUserAgent,
    );
    _showOfficeResult(res);
  }

  void _showSupervisorDialog() {
    if (!mounted || _isSupervisorDialogOpen) return;
    _isSupervisorDialogOpen = true;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E1E2E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.shield_outlined, color: Colors.amber),
                  SizedBox(width: 8),
                  Text(
                    'Panel Pengawas / Debugger',
                    style: TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: AnimatedBuilder(
                  animation: Listenable.merge([_kioskService.modeNotifier, _kioskService.manualOverrideNotifier]),
                  builder: (context, _) {
                    final currentMode = _kioskService.currentMode;
                    final isManual = _kioskService.isManualOverride;

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'Mode: ${currentMode == AssessmentMode.normal ? "NORMAL" : "UJIAN (EXAM)"}',
                              style: TextStyle(
                                color: currentMode == AssessmentMode.normal
                                    ? Colors.greenAccent
                                    : Colors.redAccent,
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: isManual ? Colors.amber.shade900 : Colors.green.shade900,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                isManual ? 'TERKUNCI MANUAL' : 'OTOMATIS (WEB)',
                                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Pilih Mode (Kunci Manual):',
                          style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        ListTile(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          tileColor: (!isManual)
                              ? Colors.blue.withValues(alpha: 0.15)
                              : Colors.transparent,
                          leading: const Icon(Icons.autorenew, color: Colors.blueAccent),
                          title: const Text('Mode Otomatis (Ikuti Portal Web)',
                              style: TextStyle(color: Colors.white, fontSize: 14)),
                          subtitle: const Text('Lepas kunci manual, ikuti URL / DOM halaman',
                              style: TextStyle(color: Colors.white54, fontSize: 11)),
                          onTap: () async {
                            _kioskService.clearManualOverride();
                            final currentUrl = await _webViewController?.getUrl();
                            if (currentUrl != null) {
                              _detector.evaluateUrl(currentUrl.toString());
                            }
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                        ),
                        const SizedBox(height: 4),
                        ListTile(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          tileColor: (isManual && currentMode == AssessmentMode.normal)
                              ? Colors.white12
                              : Colors.transparent,
                          leading: const Icon(Icons.lock_open, color: Colors.greenAccent),
                          title: const Text('Kunci: Normal (Bebas / Tanpa Kiosk)',
                              style: TextStyle(color: Colors.white, fontSize: 14)),
                          onTap: () async {
                            await _kioskService.setManualMode(AssessmentMode.normal);
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                        ),
                        const SizedBox(height: 4),
                        ListTile(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          tileColor: (isManual && currentMode != AssessmentMode.normal)
                              ? Colors.white12
                              : Colors.transparent,
                          leading: const Icon(Icons.lock, color: Colors.redAccent),
                          title: const Text('Kunci: Mode Ujian (Hanya ARA & Office Utilities)',
                              style: TextStyle(color: Colors.white, fontSize: 14)),
                          subtitle: const Text('Bolehkan Word, Excel, & PowerPoint; blokir semua aplikasi lain',
                              style: TextStyle(color: Colors.white54, fontSize: 11)),
                          onTap: () async {
                            await _kioskService.setManualMode(AssessmentMode.exam);
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                        ),
                        const Divider(color: Colors.white24, height: 24),
                        const Text(
                          'Buka Aplikasi Utilities (Word, PPT):',
                          style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF2B579A),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                ),
                                icon: const Icon(Icons.description, size: 16),
                                label: const Text('Word', style: TextStyle(fontSize: 12)),
                                onPressed: () {
                                  Navigator.pop(ctx);
                                  _handleLaunchOffice('word');
                                },
                              ),
                            ),
                            // const SizedBox(width: 8),
                            // Expanded(
                            //   child: ElevatedButton.icon(
                            //     style: ElevatedButton.styleFrom(
                            //       backgroundColor: const Color(0xFF217346),
                            //       foregroundColor: Colors.white,
                            //       padding: const EdgeInsets.symmetric(vertical: 8),
                            //     ),
                            //     icon: const Icon(Icons.table_chart, size: 16),
                            //     label: const Text('Excel', style: TextStyle(fontSize: 12)),
                            //     onPressed: () {
                            //       Navigator.pop(ctx);
                            //       _handleLaunchOffice('excel');
                            //     },
                            //   ),
                            // ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFD24726),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                ),
                                icon: const Icon(Icons.slideshow, size: 16),
                                label: const Text('PPT', style: TextStyle(fontSize: 12)),
                                onPressed: () {
                                  Navigator.pop(ctx);
                                  _handleLaunchOffice('powerpoint');
                                },
                              ),
                            ),
                          ],
                        ),
                        const Divider(color: Colors.white24, height: 24),
                        const Text(
                          'Pilih Target Server (URL Mode):',
                          style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        ListTile(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          tileColor: EnvConfig().isLocal ? Colors.blue.withValues(alpha: 0.2) : Colors.transparent,
                          leading: const Icon(Icons.computer, color: Colors.blueAccent),
                          title: const Text('Mode Local (Localhost)', style: TextStyle(color: Colors.white, fontSize: 14)),
                          subtitle: Text(EnvConfig().localUrl, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                          trailing: EnvConfig().isLocal ? const Icon(Icons.check_circle, color: Colors.blueAccent, size: 20) : null,
                          onTap: () async {
                            Navigator.pop(ctx);
                            await _switchTargetServer(AppTargetMode.local);
                          },
                        ),
                        const SizedBox(height: 4),
                        ListTile(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          tileColor: EnvConfig().isProduction ? Colors.green.withValues(alpha: 0.2) : Colors.transparent,
                          leading: const Icon(Icons.cloud_outlined, color: Colors.greenAccent),
                          title: const Text('Mode Production (Link Asli)', style: TextStyle(color: Colors.white, fontSize: 14)),
                          subtitle: Text(EnvConfig().productionUrl, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                          trailing: EnvConfig().isProduction ? const Icon(Icons.check_circle, color: Colors.greenAccent, size: 20) : null,
                          onTap: () async {
                            Navigator.pop(ctx);
                            await _switchTargetServer(AppTargetMode.production);
                          },
                        ),
                        const Divider(color: Colors.white24, height: 24),
                        const Text(
                          'Opsi Pengembang (Development):',
                          style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Development Mode', style: TextStyle(color: Colors.white, fontSize: 13)),
                          subtitle: const Text('Bolehkan Task Manager, Browser, IDE, & Alt+F4',
                              style: TextStyle(color: Colors.white54, fontSize: 11)),
                          value: _kioskService.isDevMode,
                          activeThumbColor: Colors.amber,
                          onChanged: (val) {
                            setDialogState(() {
                              setState(() {
                                _kioskService.isDevMode = val;
                                EnvConfig().isDevMode = val;
                              });
                            });
                          },
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Bypass Lockdown Window', style: TextStyle(color: Colors.white, fontSize: 13)),
                          subtitle: const Text('Nonaktifkan fullscreen, auto-minimize, & always-on-top',
                              style: TextStyle(color: Colors.white54, fontSize: 11)),
                          value: _kioskService.devBypassLockdown,
                          activeThumbColor: Colors.amber,
                          onChanged: (val) async {
                            await _kioskService.toggleDevBypassLockdown();
                            setDialogState(() {
                              setState(() {});
                            });
                          },
                        ),
                      ],
                    );
                  },
                ),
              ),
              actions: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade800),
                  icon: const Icon(Icons.power_settings_new, color: Colors.white, size: 16),
                  label: const Text('Keluar Aplikasi', style: TextStyle(color: Colors.white)),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await _kioskService.exitApp();
                  },
                ),
                TextButton(
                  onPressed: () {
                    _webViewController?.reload();
                    Navigator.pop(ctx);
                  },
                  child: const Text('Reload Web', style: TextStyle(color: Colors.blueAccent)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF605CA8)),
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Tutup', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    ).then((_) {
      _isSupervisorDialogOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AssessmentMode>(
      valueListenable: _kioskService.modeNotifier,
      builder: (context, currentMode, _) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) {
              _kioskService.handleMobileBlockedNavigation('back');
            }
          },
          child: Scaffold(
            backgroundColor: const Color(0xFF2B2B2B),
            body: SafeArea(
              top: _isMobile,
              bottom: false,
              left: false,
              right: false,
              child: Column(
                children: [
                  if (_isMobile)
                    _buildMobileTopBar(currentMode)
                  else
                    _buildDesktopMenuBar(currentMode),
                  Expanded(
                    child: KeyboardListener(
                      focusNode: _keyboardFocusNode,
                      autofocus: false,
                      onKeyEvent: (event) {
                        // Shortcut Ctrl + Shift + F12 or Alt + F12 to trigger supervisor panel
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.f12 &&
                            (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isAltPressed)) {
                          _showSupervisorDialog();
                        }
                      },
                      child: Stack(
          children: [
            // Main Webview
            if (!_isWindows || _isWebViewEnvReady)
              InAppWebView(
                key: ValueKey<String>('ara_main_webview_$_webViewRebuildKey'),
                webViewEnvironment: _webViewEnvironment,
                initialUrlRequest: URLRequest(
                  url: WebUri(_activeTargetUrl),
                ),
              initialUserScripts: UnmodifiableListView<UserScript>([
                UserScript(
                  source: _buildCameraCompatibilityScript(),
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                ),
                UserScript(
                  source: AssessmentDetector.injectedScript,
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                ),
              ]),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                allowsInlineMediaPlayback: true,
                mediaPlaybackRequiresUserGesture: false,
                useWideViewPort: true,
                loadWithOverviewMode: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                supportZoom: false,
                isInspectable: _kioskService.isDevMode || kDebugMode,
                transparentBackground: false,
                mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                thirdPartyCookiesEnabled: true,
                allowFileAccess: true,
                allowContentAccess: true,
                javaScriptCanOpenWindowsAutomatically: true,
                supportMultipleWindows: true,
                cacheEnabled: true,
                userAgent: _platformUserAgent,
                // Disable CDP Fetch.requestPaused URL interception on Windows to prevent initial navigation race conditions;
                // Office document links on Windows are handled via JS click interception + onDownloadStartRequest.
                useShouldOverrideUrlLoading: !_isWindows,
                useOnDownloadStart: true,
                // iOS & Android: prevent swipe-back/overscroll and link previews.
                allowsBackForwardNavigationGestures: false,
                allowsLinkPreview: false,
                disallowOverScroll: true,
                overScrollMode: OverScrollMode.NEVER,
              ),
                onWebViewCreated: (controller) {
                  _webViewController = controller;
                  _detector.registerJsHandlers(controller);

                  // Ensure camera compatibility & detection scripts are also registered dynamically
                  controller.addUserScript(
                    userScript: UserScript(
                      source: _buildCameraCompatibilityScript(),
                      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                    ),
                  );
                  controller.addUserScript(
                    userScript: UserScript(
                      source: AssessmentDetector.injectedScript,
                      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                    ),
                  );

                  // On Windows, explicitly trigger loadUrl after MethodChannel is ready so navigation events
                  // are guaranteed to reach Dart even if initialUrlRequest fired before initChannel.
                  if (_isWindows) {
                    final targetUrl = _activeTargetUrl;
                    _lastRequestedUrl = targetUrl;
                    Future<void>.delayed(const Duration(milliseconds: 150), () async {
                      if (!mounted) return;
                      try {
                        final cur = await controller.getUrl();
                        final curStr = cur?.toString().trim() ?? '';
                        if (curStr.isEmpty || curStr == 'about:blank') {
                          await controller.loadUrl(
                            urlRequest: URLRequest(url: WebUri(targetUrl)),
                          );
                        }
                      } catch (_) {
                        await controller.loadUrl(
                          urlRequest: URLRequest(url: WebUri(targetUrl)),
                        );
                      }
                    });
                  }
                },
              onPermissionRequest: (controller, request) async {
                debugPrint('[InAppWebView] WebRTC Permission requested: ${request.resources}');
                // Grant camera and microphone access to the web portal automatically
                return PermissionResponse(
                  resources: request.resources,
                  action: PermissionResponseAction.GRANT,
                );
              },
              onJsAlert: _handleJsAlert,
              onJsConfirm: _handleJsConfirm,
              onJsPrompt: _handleJsPrompt,
              onCreateWindow: _handleCreateWindow,
              shouldOverrideUrlLoading: _isWindows ? null : _handleNavigation,
              onDownloadStartRequest: _handleDownload,
              onLoadStart: (controller, url) {
                final urlStr = url?.toString().trim() ?? '';
                if (urlStr.isNotEmpty &&
                    urlStr != 'about:blank' &&
                    (urlStr.startsWith('http://') || urlStr.startsWith('https://'))) {
                  _lastRequestedUrl = urlStr;
                }
                setState(() {
                  if (!_hasLoadedSuccessfully) {
                    _isLoading = true;
                  }
                  _hasError = false;
                });
                _startLoadingWatchdog(resetElapsed: false);
                if (url != null) {
                  _detector.evaluateUrl(url.toString());
                }
              },
              onLoadStop: (controller, url) async {
                final loadedUrl = url?.toString().trim() ?? '';
                final isValidLoadedUrl = loadedUrl.isNotEmpty &&
                    loadedUrl != 'about:blank' &&
                    (loadedUrl.startsWith('http://') || loadedUrl.startsWith('https://'));
                if (isValidLoadedUrl) {
                  _lastRequestedUrl = loadedUrl;
                }
                _stopLoadingWatchdog();
                setState(() {
                  _isLoading = false;
                  _loadProgress = 1.0;
                  if (isValidLoadedUrl && !_hasError) {
                    _hasLoadedSuccessfully = true;
                    _autoRetryCount = 0;
                  }
                });
                if (url != null) {
                  _detector.evaluateUrl(url.toString());
                }
              },
              onUpdateVisitedHistory: (controller, url, isReload) {
                if (url != null) {
                  _detector.evaluateUrl(url.toString());
                }
              },
              onProgressChanged: (controller, progress) {
                setState(() {
                  _loadProgress = progress / 100.0;
                  if (progress >= 60) {
                    _isLoading = false;
                    _hasLoadedSuccessfully = true;
                    _stopLoadingWatchdog();
                  }
                });
              },
              onReceivedServerTrustAuthRequest: (controller, challenge) async {
                final host = challenge.protectionSpace.host;
                debugPrint('[InAppWebView] Auto-accepting SSL certificate for: $host');
                return ServerTrustAuthResponse(action: ServerTrustAuthResponseAction.PROCEED);
              },
              shouldAllowDeprecatedTLS: (controller, challenge) async {
                return ShouldAllowDeprecatedTLSAction.ALLOW;
              },
              onReceivedHttpError: (controller, request, errorResponse) {
                debugPrint('[InAppWebView] HTTP Error ${errorResponse.statusCode}: ${errorResponse.reasonPhrase} on ${request.url}');
              },
              onConsoleMessage: (controller, consoleMessage) {
                debugPrint('[InAppWebView Console] ${consoleMessage.messageLevel}: ${consoleMessage.message}');
              },
              onWebContentProcessDidTerminate: (controller) {
                debugPrint('[InAppWebView] WebKit WebContent process terminated; recovering page...');
                unawaited(_reloadOrLoadTargetUrl(forceLoadUrl: true));
              },
              onReceivedError: (controller, request, error) {
                debugPrint(
                  '[InAppWebView Error] Code: ${error.type}, Desc: ${error.description}, '
                  'URL: ${request.url}, isForMainFrame: ${request.isForMainFrame}',
                );

                // 1. Ignore subresource errors (images, fonts, analytics, iframes)
                if (request.isForMainFrame == false) {
                  return;
                }

                // 2. Ignore cancelled navigations (e.g., rapid redirects or user-initiated reload)
                if (error.type == WebResourceErrorType.CANCELLED ||
                    error.description.toLowerCase().contains('cancelled') ||
                    error.description.toLowerCase().contains('canceled')) {
                  return;
                }

                // 3. On macOS, InAppWebView.swift constructs WebResourceRequest with isForMainFrame == null.
                // If the main page has already loaded and a third-party subresource fails, do not replace the screen.
                final failingUrlStr = request.url.toString().trim();
                final failingHost = request.url.host.toLowerCase();
                final targetHost = (Uri.tryParse(EnvConfig().currentUrl)?.host ?? '').toLowerCase();
                if (_hasLoadedSuccessfully &&
                    request.isForMainFrame == null &&
                    failingHost.isNotEmpty &&
                    targetHost.isNotEmpty &&
                    failingHost != targetHost &&
                    !failingHost.endsWith('.$targetHost')) {
                  debugPrint('[InAppWebView] Ignoring third-party resource error on $failingHost');
                  return;
                }

                if (failingUrlStr.isNotEmpty &&
                    failingUrlStr != 'about:blank' &&
                    (failingUrlStr.startsWith('http://') || failingUrlStr.startsWith('https://'))) {
                  _lastRequestedUrl = failingUrlStr;
                }

                // 4. Auto-retry transient navigation failures/timeouts up to 2 times before showing error screen
                if (_autoRetryCount < 2) {
                  _autoRetryCount++;
                  debugPrint('[InAppWebView] Auto-retrying navigation (attempt $_autoRetryCount/2) for $_lastRequestedUrl...');
                  setState(() {
                    _hasError = false;
                    _isLoading = true;
                    _loadProgress = 0.0;
                  });
                  Future<void>.delayed(const Duration(milliseconds: 800), () {
                    if (mounted) {
                      unawaited(_reloadOrLoadTargetUrl(forceLoadUrl: true));
                    }
                  });
                  return;
                }

                setState(() {
                  _hasError = true;
                  _errorMessage = error.description;
                  _isLoading = false;
                });
              },
            ),

            // Top Linear Progress Bar during in-page navigation
            if (_isLoading && _loadProgress < 1.0)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(
                  value: _loadProgress,
                  minHeight: 3,
                  backgroundColor: Colors.transparent,
                  valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00AEF0)),
                ),
              ),

            // Branded Loading Overlay (prevents blank white canvas while loading)
            if (_isLoading && _loadProgress < 0.60)
              Container(
                color: const Color(0xFF2B2B2B),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.asset(
                        'assets/icon/app_icon.png',
                        width: 72,
                        height: 72,
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'ARA Assessment',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Memuat portal asesmen...',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: 140,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _loadProgress > 0 ? _loadProgress : null,
                          minHeight: 4,
                          backgroundColor: Colors.white12,
                          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00AEF0)),
                        ),
                      ),
                    ),
                    if (_loadingElapsedSeconds >= 5) ...[
                      const SizedBox(height: 20),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white38),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                        onPressed: () {
                          _autoRetryCount = 0;
                          unawaited(_reloadOrLoadTargetUrl(forceLoadUrl: true));
                        },
                        icon: const Icon(Icons.refresh_rounded, size: 16, color: Color(0xFF00AEF0)),
                        label: const Text(
                          'Muat Ulang Sekarang',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

            // Offline / Error Overlay
            if (_hasError)
              Container(
                color: const Color(0xFF1E1E2E),
                alignment: Alignment.center,
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.wifi_off_rounded, size: 64, color: Colors.redAccent),
                    const SizedBox(height: 16),
                    const Text(
                      'Gagal Membuka Halaman ARA Assessment',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _errorMessage.isNotEmpty
                          ? _errorMessage
                          : 'Periksa koneksi internet Anda lalu coba lagi.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF605CA8),
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      ),
                      onPressed: () {
                        _autoRetryCount = 0;
                        unawaited(_reloadOrLoadTargetUrl(forceLoadUrl: true));
                      },
                      icon: const Icon(Icons.refresh, color: Colors.white),
                      label: const Text('Coba Lagi', style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              ),

            // Security Violation Alert Toast / Banner
            Positioned(
              top: 16,
              left: 32,
              right: 32,
              child: ValueListenableBuilder<String?>(
                valueListenable: _kioskService.securityAlertNotifier,
                builder: (context, alertMessage, _) {
                  if (alertMessage == null) return const SizedBox.shrink();
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    decoration: BoxDecoration(
                      color: Colors.red.shade900.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: const [
                        BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, 4)),
                      ],
                      border: Border.all(color: Colors.redAccent, width: 1.5),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded, color: Colors.yellowAccent, size: 28),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            alertMessage,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  ],
),
),
),
);
},
);
}

  Future<void> _handleLaunchOffice(String val) async {
    if (_kioskService.currentMode != AssessmentMode.normal) {
      _kioskService.markOfficeSessionStarted();
    }
    OfficeLaunchResult res;
    if (val == 'word') {
      res = await OfficeLauncherService().launchWord();
    } else if (val == 'excel') {
      res = await OfficeLauncherService().launchExcel();
    } else {
      res = await OfficeLauncherService().launchPowerPoint();
    }
    if (!res.success && !res.openedStore && _kioskService.currentMode != AssessmentMode.normal) {
      _kioskService.markOfficeSessionEnded();
    }
    _showOfficeResult(res);
  }

  Widget _buildUtilitiesButton() {
    return Theme(
      data: Theme.of(context).copyWith(
        cardColor: const Color(0xFF2B2B2B),
        popupMenuTheme: PopupMenuThemeData(
          color: const Color(0xFF2B2B2B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Colors.white24, width: 1),
          ),
        ),
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white24, width: 1),
          ),
          textStyle: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      child: PopupMenuButton<String>(
        tooltip: 'Utilities (Word, PowerPoint)',
        offset: const Offset(0, 40),
        onSelected: _handleLaunchOffice,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _isMobile ? Colors.white.withValues(alpha: 0.08) : const Color(0xFF1E1E2E).withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(_isMobile ? 6 : 8),
            border: Border.all(color: _isMobile ? Colors.white12 : Colors.white24, width: 1),
            boxShadow: _isMobile
                ? null
                : const [
                    BoxShadow(color: Colors.black45, blurRadius: 6, offset: Offset(0, 2)),
                  ],
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.apps_rounded, size: 14, color: Colors.white70),
              SizedBox(width: 6),
              Text(
                'Utilities',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(width: 2),
              Icon(Icons.arrow_drop_down, size: 16, color: Colors.white70),
            ],
          ),
        ),
        itemBuilder: (ctx) => [
          const PopupMenuItem(
            value: 'word',
            child: Row(
              children: [
                Icon(Icons.description, color: Color(0xFF2B579A), size: 18),
                SizedBox(width: 10),
                Text('Microsoft Word', style: TextStyle(color: Colors.white, fontSize: 13)),
              ],
            ),
          ),
          // const PopupMenuItem(
          //   value: 'excel',
          //   child: Row(
          //     children: [
          //       Icon(Icons.table_chart, color: Color(0xFF217346), size: 18),
          //       SizedBox(width: 10),
          //       Text('Microsoft Excel', style: TextStyle(color: Colors.white, fontSize: 13)),
          //     ],
          //   ),
          // ),
          const PopupMenuItem(
            value: 'powerpoint',
            child: Row(
              children: [
                Icon(Icons.slideshow, color: Color(0xFFD24726), size: 18),
                SizedBox(width: 10),
                Text('Microsoft PowerPoint', style: TextStyle(color: Colors.white, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileTopBar(AssessmentMode currentMode) {
    final isExam = currentMode != AssessmentMode.normal;

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF2B2B2B),
        border: Border(
          bottom: BorderSide(color: Color(0xFF1E1E1E), width: 1),
        ),
      ),
      child: Row(
        children: [
          // Logo & Title
          GestureDetector(
            onDoubleTap: _showSupervisorDialog,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.asset(
                    'assets/icon/app_icon.png',
                    width: 22,
                    height: 22,
                    fit: BoxFit.contain,
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'ARA Assessment',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
                if (_kioskService.isDevMode) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: EnvConfig().isLocal ? Colors.blue.shade900 : Colors.teal.shade900,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: EnvConfig().isLocal ? Colors.blueAccent : Colors.tealAccent,
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      EnvConfig().isLocal ? 'LOCAL' : 'PROD',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Spacer(),

          // Refresh Button
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white, size: 20),
            tooltip: 'Refresh Halaman',
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: _handleRefresh,
          ),
          const SizedBox(width: 2),

          // Force Camera Button (Mobile)
          IconButton(
            icon: const Icon(Icons.videocam_rounded, color: Color(0xFF00E5FF), size: 20),
            tooltip: 'Force Kamera & Perbaikan Izin',
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: _handleForceCamera,
          ),
          const SizedBox(width: 6),

          // Utilities Dropdown Menu
          _buildUtilitiesButton(),

          // Exam Mode Indicator Badge
          if (isExam) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _showSupervisorDialog,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.red.shade900.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.redAccent, width: 0.8),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock, size: 11, color: Colors.white),
                    SizedBox(width: 4),
                    Text(
                      'EXAM',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDesktopMenuBar(AssessmentMode currentMode) {
    final isExam = currentMode != AssessmentMode.normal;

    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF2B2B2B), // Matches Windows dark title bar perfectly
        border: Border(
          bottom: BorderSide(color: Color(0xFF1E1E1E), width: 1),
        ),
      ),
      child: Row(
        children: [
          // Utilities Menu (Word, Excel, PowerPoint)
          _buildDesktopUtilitiesMenu(),

          const SizedBox(width: 4),

          // Refresh Button
          _buildDesktopRefreshButton(),

          const SizedBox(width: 4),

          // Force Camera Button (top-left right next to Refresh)
          _buildDesktopForceCameraButton(),

          // Dev Mode Controls
          if (_kioskService.isDevMode) _buildDesktopDevControls(),

          const Spacer(),

          // Exam Mode Indicator Badge on Right
          if (isExam) ...[
            Tooltip(
              message: 'Mode Ujian Aktif: Akses Word & PPT via Menu Utilities (Double-click untuk panel pengawas)',
              child: GestureDetector(
                onDoubleTap: _showSupervisorDialog,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.red.shade900.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.redAccent, width: 0.8),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock, size: 11, color: Colors.white),
                      SizedBox(width: 4),
                      Text(
                        'MODE UJIAN AKTIF',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDesktopUtilitiesMenu() {
    return Theme(
      data: Theme.of(context).copyWith(
        cardColor: const Color(0xFF1E1E1E),
        popupMenuTheme: PopupMenuThemeData(
          color: const Color(0xFF1E1E1E),
          elevation: 10,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: const BorderSide(color: Color(0xFF454545), width: 1),
          ),
        ),
      ),
      child: PopupMenuButton<String>(
        tooltip: '',
        offset: const Offset(0, 26),
        onSelected: _handleLaunchOffice,
        child: const _DesktopHoverButton(
          tooltip: 'Utilities (Word, PowerPoint)',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.apps_rounded, size: 14, color: Colors.white),
              SizedBox(width: 5),
              Text(
                'Utilities',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.2,
                ),
              ),
              SizedBox(width: 2),
              Icon(Icons.arrow_drop_down, size: 14, color: Colors.white70),
            ],
          ),
        ),
        itemBuilder: (ctx) => [
          const PopupMenuItem(
            value: 'word',
            height: 36,
            child: Row(
              children: [
                Icon(Icons.description, color: Color(0xFF2B579A), size: 18),
                SizedBox(width: 10),
                Text(
                  'Microsoft Word',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
          // const PopupMenuItem(
          //   value: 'excel',
          //   height: 36,
          //   child: Row(
          //     children: [
          //       Icon(Icons.table_chart, color: Color(0xFF217346), size: 18),
          //       SizedBox(width: 10),
          //       Text(
          //         'Microsoft Excel',
          //         style: TextStyle(
          //           color: Colors.white,
          //           fontSize: 12,
          //           fontWeight: FontWeight.w400,
          //         ),
          //       ),
          //     ],
          //   ),
          // ),
          const PopupMenuItem(
            value: 'powerpoint',
            height: 36,
            child: Row(
              children: [
                Icon(Icons.slideshow, color: Color(0xFFD24726), size: 18),
                SizedBox(width: 10),
                Text(
                  'Microsoft PowerPoint',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopRefreshButton() {
    return _DesktopHoverButton(
      tooltip: 'Refresh Halaman (${Platform.isWindows ? "F5 / Ctrl+R" : "Muat ulang"})',
      onTap: _handleRefresh,
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.refresh_rounded, size: 14, color: Colors.white),
          SizedBox(width: 4),
          Text(
            'Refresh',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopForceCameraButton() {
    return _DesktopHoverButton(
      tooltip: 'Force Kamera: Paksa aktifkan izin kamera Windows/WebView & pilih webcam',
      onTap: _handleForceCamera,
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.videocam_rounded, size: 14, color: Color(0xFF00E5FF)),
          SizedBox(width: 4),
          Text(
            'Force Kamera',
            style: TextStyle(
              color: Color(0xFF00E5FF),
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }

  Future<Map<String, dynamic>> _runCameraDiagnostics({bool elevateIfBlocked = false}) async {
    Map<String, dynamic> osStatus = {'hkcuAllowed': true, 'hklmBlocked': false, 'subkeysUpdated': 0};
    if (_isWindows) {
      osStatus = await _kioskService.forceWindowsCameraAccess(elevateIfBlocked: elevateIfBlocked);
    } else if (_isMobile) {
      await _requestInitialPermissions();
    }

    final controller = _webViewController;
    List<Map<String, String>> cameras = [];
    bool streamOk = false;
    String errorName = '';
    String errorMessage = '';
    String activeCameraLabel = '';

    if (controller != null) {
      try {
        await controller.evaluateJavascript(source: _buildCameraCompatibilityScript());
        final result = await controller.callAsyncJavaScript(
          functionBody: '''
            try {
              if (!navigator.mediaDevices || typeof navigator.mediaDevices.getUserMedia !== 'function') {
                return JSON.stringify({
                  streamOk: false,
                  errorName: 'UnsupportedContext',
                  errorMessage: 'navigator.mediaDevices tidak tersedia pada halaman ini.',
                  activeCameraLabel: '',
                  cameras: []
                });
              }
              var stream = null;
              var errName = '';
              var errMsg = '';
              var activeLabel = '';
              try {
                var pref = window.__araPreferredCameraId || '';
                var c = pref ? { video: { deviceId: { exact: pref } }, audio: false } : { video: true, audio: false };
                stream = await navigator.mediaDevices.getUserMedia(c);
                var tracks = stream.getVideoTracks();
                if (tracks && tracks.length > 0) {
                  activeLabel = tracks[0].label || 'Kamera Aktif';
                }
              } catch (err) {
                errName = (err && err.name) ? String(err.name) : 'CameraError';
                errMsg = (err && err.message) ? String(err.message) : String(err);
              } finally {
                if (stream) {
                  stream.getTracks().forEach(function(t) { try { t.stop(); } catch (_) {} });
                }
              }

              var camList = [];
              if (typeof navigator.mediaDevices.enumerateDevices === 'function') {
                var all = await navigator.mediaDevices.enumerateDevices();
                var idx = 1;
                for (var i = 0; i < all.length; i++) {
                  if (all[i] && all[i].kind === 'videoinput') {
                    camList.push({
                      deviceId: all[i].deviceId || '',
                      label: all[i].label || ('Kamera ' + idx)
                    });
                    idx++;
                  }
                }
              }

              return JSON.stringify({
                streamOk: errName === '',
                errorName: errName,
                errorMessage: errMsg,
                activeCameraLabel: activeLabel,
                cameras: camList
              });
            } catch (outerErr) {
              return JSON.stringify({
                streamOk: false,
                errorName: 'ProbeException',
                errorMessage: String(outerErr),
                activeCameraLabel: '',
                cameras: []
              });
            }
          ''',
        );

        final rawJson = result?.value?.toString() ?? '';
        if (rawJson.isNotEmpty) {
          final parsed = jsonDecode(rawJson) as Map<String, dynamic>;
          streamOk = parsed['streamOk'] == true;
          errorName = (parsed['errorName'] ?? '').toString();
          errorMessage = (parsed['errorMessage'] ?? '').toString();
          activeCameraLabel = (parsed['activeCameraLabel'] ?? '').toString();
          final rawCams = parsed['cameras'];
          if (rawCams is List) {
            cameras = rawCams
                .whereType<Map>()
                .map((m) => {
                      'deviceId': (m['deviceId'] ?? '').toString(),
                      'label': (m['label'] ?? 'Kamera').toString(),
                    })
                .toList();
          }
        }
      } catch (e) {
        errorName = 'WebViewBridgeError';
        errorMessage = e.toString();
      }
    } else {
      errorName = 'WebViewNotReady';
      errorMessage = 'Halaman belum selesai dimuat. Klik "Paksa Aktifkan & Muat Ulang".';
    }

    return {
      ...osStatus,
      'streamOk': streamOk,
      'errorName': errorName,
      'errorMessage': errorMessage,
      'activeCameraLabel': activeCameraLabel,
      'cameras': cameras,
    };
  }

  String _explainCameraError(String errorName, String errorMessage, bool hklmBlocked) {
    if (hklmBlocked) {
      return 'Izin kamera diblokir di level Sistem Windows (HKLM / Administrator). Klik tombol "Buka Kunci Sistem (Admin)" atau aktifkan lewat "Pengaturan Kamera Windows".';
    }
    final lower = '$errorName $errorMessage'.toLowerCase();
    if (lower.contains('notreadable') || lower.contains('trackstarterror') || lower.contains('in use')) {
      return 'Kamera sedang dipakai aplikasi lain (Zoom, Teams, WhatsApp, OBS, atau tab browser lain), atau pilih kamera fisik lain di daftar bawah.';
    }
    if (lower.contains('notfound') || lower.contains('devicesnotfound')) {
      return 'Perangkat kamera tidak terdeteksi oleh Windows. Pastikan webcam terpasang atau tombol fisik/Fn kamera pada keyboard laptop tidak dalam posisi OFF.';
    }
    if (lower.contains('notallowed') || lower.contains('permissiondenied')) {
      return 'Izin kamera sempat tertahan. Kami sudah memaksa izin menjadi ALLOW—klik "Paksa Aktifkan & Muat Ulang" di bawah untuk menerapkan langsung.';
    }
    if (errorMessage.isNotEmpty) {
      return '$errorName: $errorMessage';
    }
    return 'Klik "Paksa Aktifkan & Muat Ulang" untuk memuat ulang akses kamera pada halaman ini.';
  }

  Future<void> _applyForcedCameraAndReload(String? selectedDeviceId) async {
    _preferredCameraDeviceId = (selectedDeviceId != null && selectedDeviceId.isNotEmpty) ? selectedDeviceId : null;
    if (_isWindows) {
      await _kioskService.forceWindowsCameraAccess();
    }
    final controller = _webViewController;
    if (controller != null) {
      final prefValue = _preferredCameraDeviceId ?? '';
      try {
        await controller.evaluateJavascript(
          source: '''
            window.__araPreferredCameraId = ${jsonEncode(prefValue)};
            try {
              if (${jsonEncode(prefValue)}) {
                localStorage.setItem('__araPreferredCameraId', ${jsonEncode(prefValue)});
              } else {
                localStorage.removeItem('__araPreferredCameraId');
              }
            } catch (_) {}
          ''',
        );
        await controller.evaluateJavascript(source: _buildCameraCompatibilityScript());
      } catch (e) {
        debugPrint('[WebViewScreen] Error injecting preferred camera id: $e');
      }
    }
    await _reloadOrLoadTargetUrl();
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.videocam_rounded, color: Colors.white, size: 18),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Izin kamera berhasil dipaksa AKTIF & halaman sedang dimuat ulang.',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.teal.shade800,
            duration: const Duration(seconds: 3),
          ),
        );
    }
  }

  Future<void> _handleForceCamera() async {
    if (!mounted) return;

    Map<String, dynamic> diag = await _runCameraDiagnostics();
    if (!mounted) return;

    String selectedCamId = _preferredCameraDeviceId ?? '';
    bool isChecking = false;

    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final bool streamOk = diag['streamOk'] == true;
            final bool hklmBlocked = diag['hklmBlocked'] == true;
            final String errorName = (diag['errorName'] ?? '').toString();
            final String errorMessage = (diag['errorMessage'] ?? '').toString();
            final String activeCameraLabel = (diag['activeCameraLabel'] ?? '').toString();
            final List<Map<String, String>> cameras =
                (diag['cameras'] as List?)?.cast<Map<String, String>>() ?? const [];

            return AlertDialog(
              backgroundColor: const Color(0xFF1E1E2E),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: const BorderSide(color: Color(0xFF3A3A52), width: 1),
              ),
              title: const Row(
                children: [
                  Icon(Icons.videocam_rounded, color: Color(0xFF00E5FF), size: 22),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Force Kamera & Perbaikan Izin',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: streamOk
                              ? Colors.green.shade900.withValues(alpha: 0.35)
                              : Colors.orange.shade900.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: streamOk ? Colors.greenAccent : Colors.orangeAccent,
                            width: 1,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              streamOk ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                              color: streamOk ? Colors.greenAccent : Colors.orangeAccent,
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    streamOk
                                        ? 'Kamera Siap Digunakan!'
                                        : 'Perlu Pemaksaan / Penyesuaian Kamera',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    streamOk
                                        ? 'Izin kamera Windows & WebView sudah ALLOW${activeCameraLabel.isNotEmpty ? " ($activeCameraLabel)" : ""}. Klik "Paksa Aktifkan & Muat Ulang" jika tampilan kamera di halaman belum muncul.'
                                        : _explainCameraError(errorName, errorMessage, hklmBlocked),
                                    style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.4),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_isWindows && hklmBlocked) ...[
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.amberAccent,
                              side: const BorderSide(color: Colors.amberAccent),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            ),
                            onPressed: isChecking
                                ? null
                                : () async {
                                    setDialogState(() => isChecking = true);
                                    final nextDiag = await _runCameraDiagnostics(elevateIfBlocked: true);
                                    if (ctx.mounted) {
                                      setDialogState(() {
                                        diag = nextDiag;
                                        isChecking = false;
                                      });
                                    }
                                  },
                            icon: const Icon(Icons.admin_panel_settings_rounded, size: 18),
                            label: const Text(
                              'Buka Kunci Kamera Sistem Windows (Admin / UAC)',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      const Text(
                        'Pilih Perangkat Kamera:',
                        style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 6),
                      RadioGroup<String>(
                        groupValue: selectedCamId,
                        onChanged: (val) {
                          setDialogState(() => selectedCamId = val ?? '');
                        },
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            RadioListTile<String>(
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                              value: '',
                              activeColor: const Color(0xFF00E5FF),
                              title: const Text(
                                'Otomatis (Prioritaskan Kamera Fisik Laptop / USB)',
                                style: TextStyle(color: Colors.white, fontSize: 12.5),
                              ),
                            ),
                            ...cameras
                                .where((c) => (c['deviceId'] ?? '').isNotEmpty)
                                .map(
                                  (cam) => RadioListTile<String>(
                                    dense: true,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                                    value: cam['deviceId']!,
                                    activeColor: const Color(0xFF00E5FF),
                                    title: Text(
                                      cam['label'] ?? 'Kamera',
                                      style: const TextStyle(color: Colors.white, fontSize: 12.5),
                                    ),
                                  ),
                                ),
                          ],
                        ),
                      ),
                      if (cameras.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 4, left: 6),
                          child: Text(
                            'Belum ada perangkat video yang terbaca oleh browser.',
                            style: TextStyle(color: Colors.white54, fontSize: 11.5),
                          ),
                        ),
                      if (_isWindows) ...[
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () {
                              unawaited(_kioskService.openWindowsCameraPrivacySettings());
                            },
                            icon: const Icon(Icons.settings_rounded, size: 16, color: Colors.white70),
                            label: const Text(
                              'Buka Pengaturan Privasi Kamera Windows',
                              style: TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Tutup', style: TextStyle(color: Colors.white60)),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white24),
                  ),
                  onPressed: isChecking
                      ? null
                      : () async {
                          setDialogState(() => isChecking = true);
                          _preferredCameraDeviceId = selectedCamId.isNotEmpty ? selectedCamId : null;
                          final nextDiag = await _runCameraDiagnostics();
                          if (ctx.mounted) {
                            setDialogState(() {
                              diag = nextDiag;
                              isChecking = false;
                            });
                          }
                        },
                  icon: isChecking
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.sync_rounded, size: 16),
                  label: const Text('Tes Ulang', style: TextStyle(fontSize: 12)),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00AEF0),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    unawaited(_applyForcedCameraAndReload(selectedCamId));
                  },
                  icon: const Icon(Icons.bolt_rounded, size: 17),
                  label: const Text(
                    'Paksa Aktifkan & Muat Ulang',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildDesktopDevControls() {
    final isLocal = EnvConfig().isLocal;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          width: 1,
          height: 16,
          color: Colors.white24,
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.amber.shade900,
            borderRadius: BorderRadius.circular(3),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.developer_mode, size: 11, color: Colors.white),
              SizedBox(width: 3),
              Text(
                'DEV',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        // Target Server Switcher (Local vs Production)
        _DesktopHoverButton(
          tooltip: 'Target Server: ${isLocal ? "Localhost (${EnvConfig().localUrl})" : "Production (${EnvConfig().productionUrl})"} (Klik ganti / Ctrl+Shift+L)',
          onTap: () {
            final next = isLocal ? AppTargetMode.production : AppTargetMode.local;
            _switchTargetServer(next);
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isLocal ? Icons.computer : Icons.cloud_outlined,
                size: 13,
                color: isLocal ? Colors.lightBlueAccent : Colors.greenAccent,
              ),
              const SizedBox(width: 4),
              Text(
                isLocal ? 'Localhost' : 'Production',
                style: TextStyle(
                  color: isLocal ? Colors.lightBlueAccent : Colors.greenAccent,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        _DesktopHoverButton(
          tooltip: 'Buka panel pengawas ujian (F12)',
          onTap: _showSupervisorDialog,
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.settings, size: 13, color: Colors.white70),
              SizedBox(width: 4),
              Text(
                'Panel (F12)',
                style: TextStyle(color: Colors.white, fontSize: 11),
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        _DesktopHoverButton(
          tooltip: 'Keluar dari aplikasi',
          onTap: () => _kioskService.exitApp(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.power_settings_new, size: 13, color: Colors.red.shade300),
              const SizedBox(width: 4),
              Text(
                'Keluar (Esc)',
                style: TextStyle(color: Colors.red.shade300, fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DesktopHoverButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final String? tooltip;

  const _DesktopHoverButton({
    required this.child,
    this.onTap,
    this.tooltip,
  });

  @override
  State<_DesktopHoverButton> createState() => _DesktopHoverButtonState();
}

class _DesktopHoverButtonState extends State<_DesktopHoverButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    Widget widgetChild = MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: _isHovered ? const Color(0xFF3C3C3D) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: widget.child,
      ),
    );

    if (widget.onTap != null) {
      widgetChild = GestureDetector(
        onTap: widget.onTap,
        child: widgetChild,
      );
    }

    if (widget.tooltip != null && widget.tooltip!.isNotEmpty) {
      return Tooltip(
        message: widget.tooltip!,
        child: widgetChild,
      );
    }

    return widgetChild;
  }
}
