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
        var currentUrl = window.location.href.toLowerCase();
        var bodyText = document.body ? document.body.innerText.toLowerCase() : '';

        // Check if page contains essay-specific elements or text
        var isEssay = currentUrl.indexOf('essay') !== -1 ||
                      currentUrl.indexOf('esai') !== -1 ||
                      document.getElementById('answerText') !== null ||
                      document.querySelector('.cke_editor_answerText') !== null ||
                      (bodyText.indexOf('soal essay') !== -1 || bodyText.indexOf('soal esai') !== -1);

        // Check if page is inside active exam
        var isExam = currentUrl.indexOf('/ujian') !== -1 ||
                     currentUrl.indexOf('/exam') !== -1 ||
                     currentUrl.indexOf('/assessment') !== -1 ||
                     currentUrl.indexOf('/soal') !== -1 ||
                     document.querySelector('.timer') !== null ||
                     document.querySelector('.exam-timer') !== null;

        var isFinished = currentUrl.indexOf('/selesai') !== -1 ||
                         currentUrl.indexOf('/finish') !== -1 ||
                         currentUrl.indexOf('/dashboard') !== -1 ||
                         currentUrl.indexOf('/login') !== -1;

        if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
          if (isFinished) {
            window.flutter_inappwebview.callHandler('onAssessmentStateChange', 'normal');
          } else if (isEssay) {
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
    final lower = url.toLowerCase();
    debugPrint('[AssessmentDetector] Navigated to URL: $lower');

    if (lower.contains('/selesai') ||
        lower.contains('/finish') ||
        lower.contains('/dashboard') ||
        lower.contains('/login') ||
        lower.endsWith('ara-assessment.com/') ||
        lower == 'https://ara-assessment.com') {
      _kioskService.setMode(AssessmentMode.normal);
      return;
    }

    if (lower.contains('/essay') || lower.contains('/esai')) {
      _kioskService.setMode(AssessmentMode.essayExam);
      return;
    }

    if (lower.contains('/ujian') ||
        lower.contains('/exam') ||
        lower.contains('/assessment') ||
        lower.contains('/soal') ||
        lower.contains('/test')) {
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
