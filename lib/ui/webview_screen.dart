import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/assessment_detector.dart';
import '../services/kiosk_security_service.dart';

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  InAppWebViewController? _webViewController;
  final KioskSecurityService _kioskService = KioskSecurityService();
  final AssessmentDetector _detector = AssessmentDetector();

  bool _isLoading = true;
  double _loadProgress = 0.0;
  bool _hasError = false;
  String _errorMessage = '';

  final FocusNode _keyboardFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _requestInitialPermissions();
  }

  @override
  void dispose() {
    _keyboardFocusNode.dispose();
    super.dispose();
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
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E2E),
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
          content: ValueListenableBuilder<AssessmentMode>(
            valueListenable: _kioskService.modeNotifier,
            builder: (context, currentMode, _) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Status Mode Saat Ini: ${currentMode.name.toUpperCase()}',
                    style: TextStyle(
                      color: currentMode == AssessmentMode.strictExam
                          ? Colors.redAccent
                          : currentMode == AssessmentMode.essayExam
                              ? Colors.orangeAccent
                              : Colors.greenAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Ubah Mode Keamanan Secara Manual:',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    tileColor: currentMode == AssessmentMode.normal
                        ? Colors.white12
                        : Colors.transparent,
                    leading: const Icon(Icons.lock_open, color: Colors.greenAccent),
                    title: const Text('Normal (Bebas / Tanpa Kiosk)',
                        style: TextStyle(color: Colors.white, fontSize: 14)),
                    onTap: () {
                      _kioskService.setMode(AssessmentMode.normal);
                      Navigator.pop(ctx);
                    },
                  ),
                  ListTile(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    tileColor: currentMode == AssessmentMode.strictExam
                        ? Colors.white12
                        : Colors.transparent,
                    leading: const Icon(Icons.lock, color: Colors.redAccent),
                    title: const Text('Strict Exam (Hanya ARA)',
                        style: TextStyle(color: Colors.white, fontSize: 14)),
                    subtitle: const Text('Blokir semua aplikasi lain',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                    onTap: () {
                      _kioskService.setMode(AssessmentMode.strictExam);
                      Navigator.pop(ctx);
                    },
                  ),
                  ListTile(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    tileColor: currentMode == AssessmentMode.essayExam
                        ? Colors.white12
                        : Colors.transparent,
                    leading: const Icon(Icons.edit_note, color: Colors.orangeAccent),
                    title: const Text('Essay Exam (Word & PPT Saja)',
                        style: TextStyle(color: Colors.white, fontSize: 14)),
                    subtitle: const Text('Bolehkan Word & PowerPoint',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                    onTap: () {
                      _kioskService.setMode(AssessmentMode.essayExam);
                      Navigator.pop(ctx);
                    },
                  ),
                ],
              );
            },
          ),
          actions: [
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
                url: WebUri('https://ara-assessment.com/assess'),
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

            // Discreet Active Mode Badge (Top-Right)
            Positioned(
              top: 8,
              right: 8,
              child: ValueListenableBuilder<AssessmentMode>(
                valueListenable: _kioskService.modeNotifier,
                builder: (context, mode, _) {
                  if (mode == AssessmentMode.normal) return const SizedBox.shrink();
                  final isStrict = mode == AssessmentMode.strictExam;
                  return GestureDetector(
                    onDoubleTap: _showSupervisorDialog,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: (isStrict ? Colors.red.shade900 : Colors.amber.shade900)
                            .withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isStrict ? Colors.redAccent : Colors.amberAccent,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isStrict ? Icons.lock : Icons.edit_note,
                            size: 14,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isStrict ? 'LOCKDOWN AKTIF' : 'MODE ESSAY (WORD & PPT)',
                            style: const TextStyle(
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
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
