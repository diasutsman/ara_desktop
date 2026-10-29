import 'dart:async';
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
  InAppWebViewController? _webViewController;
  final KioskSecurityService _kioskService = KioskSecurityService();
  final AssessmentDetector _detector = AssessmentDetector();

  bool _isLoading = true;
  double _loadProgress = 0.0;
  bool _hasError = false;
  String _errorMessage = '';
  bool _hasLoadedSuccessfully = false;
  int _autoRetryCount = 0;
  String? _lastRequestedUrl;

  final FocusNode _keyboardFocusNode = FocusNode();
  bool _isSupervisorDialogOpen = false;

  bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

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
    _kioskService.onRefreshRequested = _handleRefresh;
    _kioskService.onViolationDetected = _handleKioskViolation;
    HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      windowManager.addListener(this);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      windowManager.removeListener(this);
    }
    _kioskService.onRefreshRequested = null;
    _kioskService.onViolationDetected = null;
    HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    _detector.onSupervisorRequested = null;
    _keyboardFocusNode.dispose();
    super.dispose();
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

    final controller = _webViewController;
    if (controller == null) return;

    final fallbackUrl = EnvConfig().currentUrl;
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
                      autofocus: !_isMobile,
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
            InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri(EnvConfig().currentUrl),
              ),
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
                cacheEnabled: true,
                userAgent: _platformUserAgent,
                // Enable URL interception & download handlers across platforms for Office integration
                useShouldOverrideUrlLoading: true,
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

                // Inject detection script
                controller.addUserScript(
                  userScript: UserScript(
                    source: AssessmentDetector.injectedScript,
                    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                  ),
                );
              },
              onPermissionRequest: (controller, request) async {
                debugPrint('[InAppWebView] WebRTC Permission requested: ${request.resources}');
                // Grant camera and microphone access to the web portal automatically
                return PermissionResponse(
                  resources: request.resources,
                  action: PermissionResponseAction.GRANT,
                );
              },
              shouldOverrideUrlLoading: _handleNavigation,
              onDownloadStartRequest: _handleDownload,
              onLoadStart: (controller, url) {
                final urlStr = url?.toString().trim() ?? '';
                if (urlStr.isNotEmpty &&
                    urlStr != 'about:blank' &&
                    (urlStr.startsWith('http://') || urlStr.startsWith('https://'))) {
                  _lastRequestedUrl = urlStr;
                }
                setState(() {
                  _isLoading = true;
                  _hasError = false;
                });
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
                setState(() {
                  _isLoading = false;
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
                  if (progress == 100) {
                    _isLoading = false;
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
            if (_isLoading && _loadProgress < 0.95)
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
                      'ARA Mobile',
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
                  'ARA Mobile',
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
