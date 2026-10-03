import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'kiosk_security_service.dart';

class AssessmentDetector {
  static final AssessmentDetector _instance = AssessmentDetector._internal();
  factory AssessmentDetector() => _instance;
  AssessmentDetector._internal();

  final KioskSecurityService _kioskService = KioskSecurityService();

  // JavaScript snippet injected into every web page loaded
  static const String injectedScript = """
    (function() {
      // Expose helper API for web portal to invoke if custom integration is used
      window.setAraAssessmentMode = function(mode) {
        if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
          window.flutter_inappwebview.callHandler('onAssessmentStateChange', mode);
        }
      };

      // Periodic DOM observer to detect essay indicators or exam buttons
      function detectStateFromDOM() {
        var pathname = window.location.pathname.toLowerCase();
        var bodyText = document.body ? document.body.innerText.toLowerCase() : '';

        // Check if on Landing, Login, Register, or Dashboard pages (Normal mode)
        var isNormal = pathname === '' ||
                       pathname === '/' ||
                       pathname === '/assess' ||
                       pathname === '/assess/' ||
                       pathname.indexOf('/login') !== -1 ||
                       pathname.indexOf('/register') !== -1 ||
                       pathname.indexOf('/dashboard') !== -1 ||
                       pathname.indexOf('/selesai') !== -1 ||
                       pathname.indexOf('/finish') !== -1;

        if (isNormal) {
          if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
            window.flutter_inappwebview.callHandler('onAssessmentStateChange', 'normal');
          }
          return;
        }

        // Check if page contains essay-specific elements or text
        var isEssay = pathname.indexOf('/essay') !== -1 ||
                      pathname.indexOf('/esai') !== -1 ||
                      pathname.indexOf('/uraian') !== -1 ||
                      document.getElementById('answerText') !== null ||
                      document.querySelector('.cke_editor_answerText') !== null ||
                      (bodyText.indexOf('soal essay') !== -1 || bodyText.indexOf('soal esai') !== -1);

        // Check if page is inside an active exam session
        var isExam = pathname.indexOf('/ujian') !== -1 ||
                     pathname.indexOf('/exam') !== -1 ||
                     pathname.indexOf('/soal') !== -1 ||
                     pathname.indexOf('/test') !== -1 ||
                     pathname.indexOf('/mulai') !== -1 ||
                     pathname.indexOf('/kerjakan') !== -1 ||
                     document.querySelector('.timer') !== null ||
                     document.querySelector('.exam-timer') !== null;

        if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
          if (isEssay) {
            window.flutter_inappwebview.callHandler('onAssessmentStateChange', 'essay');
          } else if (isExam) {
            window.flutter_inappwebview.callHandler('onAssessmentStateChange', 'strict');
          }
        }
      }

      // Run detection when DOM is loaded and every 2 seconds
      document.addEventListener('DOMContentLoaded', detectStateFromDOM);
      setInterval(detectStateFromDOM, 2000);
    })();
  """;

  void registerJsHandlers(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'onAssessmentStateChange',
      callback: (args) {
        if (args.isNotEmpty) {
          final modeStr = args[0].toString().toLowerCase();
          debugPrint('[AssessmentDetector] JS reported mode: $modeStr');
          handleModeChange(modeStr);
        }
      },
    );
  }

  void evaluateUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    final path = uri.path.toLowerCase();
    debugPrint('[AssessmentDetector] Evaluated URL path: $path (full: $url)');

    // 1. Normal / Landing / Login / Dashboard / Finished
    if (path == '' ||
        path == '/' ||
        path == '/assess' ||
        path == '/assess/' ||
        path.contains('/login') ||
        path.contains('/register') ||
        path.contains('/dashboard') ||
        path.contains('/selesai') ||
        path.contains('/finish')) {
      _kioskService.setMode(AssessmentMode.normal);
      return;
    }

    // 2. Essay Exam routes
    if (path.contains('/essay') ||
        path.contains('/esai') ||
        path.contains('/uraian')) {
      _kioskService.setMode(AssessmentMode.essayExam);
      return;
    }

    // 3. Strict Exam routes
    if (path.contains('/ujian') ||
        path.contains('/exam') ||
        path.contains('/soal') ||
        path.contains('/test') ||
        path.contains('/mulai') ||
        path.contains('/kerjakan') ||
        path.contains('/start')) {
      _kioskService.setMode(AssessmentMode.strictExam);
      return;
    }
  }

  void handleModeChange(String mode) {
    switch (mode) {
      case 'strict':
      case 'exam':
        _kioskService.setMode(AssessmentMode.strictExam);
        break;
      case 'essay':
        _kioskService.setMode(AssessmentMode.essayExam);
        break;
      case 'normal':
      case 'idle':
      default:
        _kioskService.setMode(AssessmentMode.normal);
        break;
    }
  }
}
