import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'kiosk_security_service.dart';

class AssessmentDetector {
  static final AssessmentDetector _instance = AssessmentDetector._internal();
  factory AssessmentDetector() => _instance;
  AssessmentDetector._internal();

  final KioskSecurityService _kioskService = KioskSecurityService();

  /// Callback when supervisor panel is requested via in-page shortcut
  VoidCallback? onSupervisorRequested;

  // JavaScript snippet injected into every web page loaded
  static const String injectedScript = """
    (function() {
      // Expose helper API for web portal to invoke if custom integration is used
      window.setAraAssessmentMode = function(mode) {
        if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
          window.flutter_inappwebview.callHandler('onAssessmentStateChange', mode);
        }
      };

      // Listen for emergency dev keys & supervisor panel inside WebView
      document.addEventListener('keydown', function(e) {
        if ((e.key === 'F12' || e.keyCode === 123) && (e.ctrlKey || e.altKey || e.shiftKey)) {
          if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
            window.flutter_inappwebview.callHandler('onSupervisorPanelTrigger');
          }
        }
        if (e.key === 'Escape' || (e.ctrlKey && (e.key === 'q' || e.key === 'Q'))) {
          if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
            window.flutter_inappwebview.callHandler('onDevExitTrigger');
          }
        }
      });

      var lastReportedMode = '';

      function reportMode(mode) {
        if (mode === lastReportedMode) return;
        lastReportedMode = mode;
        if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
          window.flutter_inappwebview.callHandler('onAssessmentStateChange', mode);
        }
      }

      // Periodic DOM observer to detect essay indicators or exam buttons
      function detectStateFromDOM() {
        var pathname = window.location.pathname.toLowerCase();

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
          reportMode('normal');
          return;
        }

        // Check if page is inside an active exam session
        var isExam = pathname.indexOf('/ujian') !== -1 ||
                     pathname.indexOf('/exam') !== -1 ||
                     pathname.indexOf('/soal') !== -1 ||
                     pathname.indexOf('/test') !== -1 ||
                     pathname.indexOf('/cbt') !== -1 ||
                     pathname.indexOf('/quiz') !== -1 ||
                     pathname.indexOf('/mulai') !== -1 ||
                     pathname.indexOf('/kerjakan') !== -1 ||
                     document.querySelector('.timer') !== null ||
                     document.querySelector('.exam-timer') !== null;

        // Check if page contains essay-specific elements or route
        var isEssayRoute = pathname.indexOf('/essay') !== -1 ||
                           pathname.indexOf('/esai') !== -1 ||
                           pathname.indexOf('/uraian') !== -1;

        var hasEssayEditor = document.getElementById('answerText') !== null ||
                             document.querySelector('.cke_editor_answerText') !== null;

        if (isEssayRoute || (isExam && hasEssayEditor)) {
          reportMode('essay');
        } else if (isExam) {
          reportMode('strict');
        }
      }

      // Run detection when DOM is loaded and periodically every 2 seconds
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

    controller.addJavaScriptHandler(
      handlerName: 'onDevExitTrigger',
      callback: (args) {
        if (_kioskService.isDevMode) {
          debugPrint('[AssessmentDetector] Dev exit triggered via WebView JS shortcut');
          _kioskService.exitApp();
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'onSupervisorPanelTrigger',
      callback: (args) {
        debugPrint('[AssessmentDetector] Supervisor panel triggered via WebView JS shortcut');
        onSupervisorRequested?.call();
      },
    );
  }

  void evaluateUrl(String url) {
    if (_kioskService.isManualOverride) {
      debugPrint('[AssessmentDetector] Manual Mode Lock is ACTIVE. Ignoring evaluateUrl($url).');
      return;
    }

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

    // 3. Strict Exam routes (ujian / exam / soal / test / cbt / quiz / mulai / kerjakan)
    if (path.contains('/ujian') ||
        path.contains('/exam') ||
        path.contains('/soal') ||
        path.contains('/test') ||
        path.contains('/cbt') ||
        path.contains('/quiz') ||
        path.contains('/mulai') ||
        path.contains('/kerjakan') ||
        path.contains('/start')) {
      _kioskService.setMode(AssessmentMode.strictExam);
      return;
    }
  }

  void handleModeChange(String mode) {
    if (_kioskService.isManualOverride) {
      debugPrint('[AssessmentDetector] Manual Mode Lock is ACTIVE. Ignoring handleModeChange($mode).');
      return;
    }

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
