import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
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
    HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    _detector.onSupervisorRequested = null;
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  void _handleRefresh() {
    if (!mounted) return;
    debugPrint('[WebViewScreen] Refreshing page...');
    setState(() {
      _hasError = false;
      _isLoading = true;
    });
    _webViewController?.reload();
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
      // Refresh hotkeys: F5 or Ctrl+R
      if (event.logicalKey == LogicalKeyboardKey.f5 ||
          (HardwareKeyboard.instance.isControlPressed && event.logicalKey == LogicalKeyboardKey.keyR)) {
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
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      try {
        final cameraStatus = await Permission.camera.request();
        final micStatus = await Permission.microphone.request();
        debugPrint('[Permissions] Camera: $cameraStatus, Mic: $micStatus');
      } catch (e) {
        debugPrint('[Permissions] Error requesting hardware permissions: $e');
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

  Future<NavigationActionPolicy> _handleMobileNavigation(
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

  Future<void> _handleMobileDownload(
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
                          'Opsi Pengembang (Development):',
                          style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Development Mode', style: TextStyle(color: Colors.white, fontSize: 13)),
                          subtitle: const Text('Bolehkan Task Manager, IDE, & Alt+F4',
                              style: TextStyle(color: Colors.white54, fontSize: 11)),
                          value: _kioskService.isDevMode,
                          activeThumbColor: Colors.amber,
                          onChanged: (val) {
                            setDialogState(() {
                              setState(() {
                                _kioskService.isDevMode = val;
                              });
                            });
                          },
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Bypass Lockdown Window', style: TextStyle(color: Colors.white, fontSize: 13)),
                          subtitle: const Text('Nonaktifkan fullscreen & always-on-top',
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
        final isExam = currentMode != AssessmentMode.normal;
        return PopScope(
          canPop: !isExam,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Tombol navigasi dinonaktifkan selama Mode Ujian.'),
                  duration: Duration(seconds: 2),
                  backgroundColor: Colors.red,
                ),
              );
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
                  if (_isMobile) _buildMobileTopBar(currentMode),
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
                      url: WebUri('http://localhost/new_ara'),
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
                isInspectable: kDebugMode,
                transparentBackground: false,
                mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                thirdPartyCookiesEnabled: true,
                allowFileAccess: true,
                allowContentAccess: true,
                javaScriptCanOpenWindowsAutomatically: true,
                cacheEnabled: true,
                userAgent: _platformUserAgent,
                // Mobile-only hooks for opening portal Office documents (desktop unchanged).
                useShouldOverrideUrlLoading: _isMobile,
                useOnDownloadStart: _isMobile,
                // iOS: WKWebView swipe-back bypasses PopScope, and link previews can escape to Safari.
                allowsBackForwardNavigationGestures: false,
                allowsLinkPreview: false,
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
              // Passed as null on desktop: flutter_inappwebview auto-enables these hooks when set.
              shouldOverrideUrlLoading: _isMobile ? _handleMobileNavigation : null,
              onDownloadStartRequest: _isMobile ? _handleMobileDownload : null,
              onLoadStart: (controller, url) {
                setState(() {
                  _isLoading = true;
                  _hasError = false;
                });
                if (url != null) {
                  _detector.evaluateUrl(url.toString());
                }
              },
              onLoadStop: (controller, url) async {
                setState(() {
                  _isLoading = false;
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
                debugPrint('[InAppWebView] SSL ServerTrustAuthRequest for: ${challenge.protectionSpace.host}');
                return ServerTrustAuthResponse(action: ServerTrustAuthResponseAction.PROCEED);
              },
              onReceivedHttpError: (controller, request, errorResponse) {
                debugPrint('[InAppWebView] HTTP Error ${errorResponse.statusCode}: ${errorResponse.reasonPhrase} on ${request.url}');
              },
              onConsoleMessage: (controller, consoleMessage) {
                debugPrint('[InAppWebView Console] ${consoleMessage.messageLevel}: ${consoleMessage.message}');
              },
              onReceivedError: (controller, request, error) {
                debugPrint('[InAppWebView Error] Code: ${error.type}, Desc: ${error.description}');
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
                        setState(() {
                          _hasError = false;
                          _isLoading = true;
                        });
                        _webViewController?.reload();
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

            // Top-Right Floating Bar: Refresh Button & Active Mode Badge (Desktop)
            if (!_isMobile)
              Positioned(
                top: 8,
                right: 8,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Floating Refresh Button
                    Tooltip(
                      message: 'Muat ulang halaman portal (F5 / Ctrl+R)',
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _handleRefresh,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E1E2E).withValues(alpha: 0.9),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.white24, width: 1),
                              boxShadow: const [
                                BoxShadow(color: Colors.black45, blurRadius: 6, offset: Offset(0, 2)),
                              ],
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.refresh_rounded, size: 14, color: Colors.white),
                                SizedBox(width: 5),
                                Text(
                                  'Refresh',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ValueListenableBuilder<AssessmentMode>(
                      valueListenable: _kioskService.modeNotifier,
                      builder: (context, mode, _) {
                        if (mode != AssessmentMode.normal) {
                          return Tooltip(
                            message: 'Mode Ujian Aktif: Akses Word, Excel & PPT via Menu Utilities',
                            child: GestureDetector(
                              onDoubleTap: _showSupervisorDialog,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade900.withValues(alpha: 0.85),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: Colors.redAccent,
                                    width: 1,
                                  ),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.lock,
                                      size: 14,
                                      color: Colors.white,
                                    ),
                                    SizedBox(width: 4),
                                    Text(
                                      'MODE UJIAN AKTIF (WORD, EXCEL, PPT)',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }

                        // Normal Mode: Tidak menampilkan badge mode ujian
                        return const SizedBox.shrink();
                      },
                    ),
                  ],
                ),
              ),

            // Floating Dev Mode Toolbar & Emergency Exit Button (Top-Left)
            if (_kioskService.isDevMode)
              Positioned(
                top: 8,
                left: 8,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E2E).withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.amberAccent.shade400, width: 1.5),
                      boxShadow: const [
                        BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 3)),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.amber.shade800,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.developer_mode, size: 12, color: Colors.white),
                              SizedBox(width: 4),
                              Text(
                                'DEV MODE',
                                style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Quick supervisor dialog
                        InkWell(
                          onTap: _showSupervisorDialog,
                          borderRadius: BorderRadius.circular(4),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white12,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.settings, size: 12, color: Colors.white70),
                                SizedBox(width: 4),
                                Text('Panel (F12)', style: TextStyle(color: Colors.white, fontSize: 11)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Emergency Exit Button (Always available in dev mode)
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade700,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            elevation: 2,
                          ),
                          icon: const Icon(Icons.power_settings_new, size: 14),
                          label: const Text(
                            'KELUAR (Esc / Alt+F4)',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                          onPressed: () => _kioskService.exitApp(),
                        ),
                      ],
                    ),
                  ),
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
              ],
            ),
          ),
          const Spacer(),

          // Mobile Refresh Button
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white, size: 20),
            tooltip: 'Refresh Halaman',
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: _handleRefresh,
          ),
          const SizedBox(width: 4),

          // Utilities Dropdown Menu
          Theme(
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
              tooltip: 'Utilities',
              offset: const Offset(0, 40),
              onSelected: (val) async {
                _kioskService.markOfficeSessionStarted();
                OfficeLaunchResult res;
                if (val == 'word') {
                  res = await OfficeLauncherService().launchWord();
                } else if (val == 'excel') {
                  res = await OfficeLauncherService().launchExcel();
                } else {
                  res = await OfficeLauncherService().launchPowerPoint();
                }
                _showOfficeResult(res);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white12),
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
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
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
                const PopupMenuItem(
                  value: 'excel',
                  child: Row(
                    children: [
                      Icon(Icons.table_chart, color: Color(0xFF217346), size: 18),
                      SizedBox(width: 10),
                      Text('Microsoft Excel', style: TextStyle(color: Colors.white, fontSize: 13)),
                    ],
                  ),
                ),
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
          ),

          // Exam Mode Indicator Badge on Mobile Top Bar
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
}
