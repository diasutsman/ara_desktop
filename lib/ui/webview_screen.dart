import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:window_manager/window_manager.dart';
import '../services/assessment_detector.dart';
import '../services/kiosk_security_service.dart';

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> with WindowListener {
  InAppWebViewController? _webViewController;
  final KioskSecurityService _kioskService = KioskSecurityService();
  final AssessmentDetector _detector = AssessmentDetector();

  bool _isLoading = true;
  double _loadProgress = 0.0;
  bool _hasError = false;
  String _errorMessage = '';

  final FocusNode _keyboardFocusNode = FocusNode();
  bool _isSupervisorDialogOpen = false;

  @override
  void initState() {
    super.initState();
    _requestInitialPermissions();
    _detector.onSupervisorRequested = _showSupervisorDialog;
    HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      windowManager.addListener(this);
    }
  }

  @override
  void dispose() {
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      windowManager.removeListener(this);
    }
    HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    _detector.onSupervisorRequested = null;
    _keyboardFocusNode.dispose();
    super.dispose();
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: KeyboardListener(
        focusNode: _keyboardFocusNode,
        autofocus: true,
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
                      url: WebUri('https://ara-assessment.com/assess/login'),
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
              onReceivedError: (controller, request, error) {
                setState(() {
                  _hasError = true;
                  _errorMessage = error.description;
                  _isLoading = false;
                });
              },
            ),

            // Top Linear Progress Bar when page loads
            if (_isLoading && _loadProgress < 1.0)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(
                  value: _loadProgress,
                  minHeight: 3,
                  backgroundColor: Colors.transparent,
                  valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF605CA8)),
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

            // Discreet Active Mode Badge or Window Controls (Top-Right)
            Positioned(
              top: 8,
              right: 8,
              child: ValueListenableBuilder<AssessmentMode>(
                valueListenable: _kioskService.modeNotifier,
                builder: (context, mode, _) {
                  if (mode != AssessmentMode.normal) {
                    return GestureDetector(
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
                    );
                  }

                  // Normal Mode: Gunakan kontrol jendela native bawaan Windows (minimize, maximize, close).
                  // Tidak menampilkan tombol ganda di dalam webview.
                  return const SizedBox.shrink();
                },
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
    );
  }
}
