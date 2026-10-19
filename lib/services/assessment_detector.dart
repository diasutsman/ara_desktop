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

  /// Latest user/exam context reported by the WebView DOM
  final Map<String, String> lastExamContext = {};

  // JavaScript snippet injected into every web page loaded
  static const String injectedScript = """
    (function() {
      // Expose helper API for web portal to invoke if custom integration is used
      window.setAraAssessmentMode = function(mode) {
        if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
          window.flutter_inappwebview.callHandler('onAssessmentStateChange', mode);
        }
      };

      function resolvePortalBaseUrl() {
        try {
          var origin = window.location.origin || '';
          var path = window.location.pathname || '';
          if (path.indexOf('/new_ara') === 0) {
            return origin + '/new_ara';
          }
          if (path.indexOf('/assess') === 0) {
            return origin + '/assess';
          }
          var parts = path.split('/').filter(Boolean);
          if (parts.length > 0 && ['login', 'home', 'exam', 'user', 'violation', 'dashboard', 'result'].indexOf(parts[0].toLowerCase()) === -1) {
            return origin + '/' + parts[0];
          }
          return origin;
        } catch (_) {
          return '';
        }
      }

      var lastContextSignature = '';
      function syncExamContextFromDOM() {
        try {
          var userEl = document.getElementById('hid_user_id');
          var examEl = document.getElementById('hid_exam_id');
          var classEl = document.getElementById('hid_class_id');
          var respEl = document.getElementById('hid_response');

          var userID = (userEl && userEl.value) ? String(userEl.value).trim() : (localStorage.getItem('ara_last_user_id') || '');
          var examID = (examEl && examEl.value) ? String(examEl.value).trim() : (localStorage.getItem('ara_last_exam_id') || '');
          var classID = (classEl && classEl.value) ? String(classEl.value).trim() : (localStorage.getItem('ara_last_class_id') || '');
          var responseID = (respEl && respEl.value) ? String(respEl.value).trim() : (localStorage.getItem('ara_last_response_id') || '');
          var baseUrl = resolvePortalBaseUrl();

          if (userEl && userEl.value) localStorage.setItem('ara_last_user_id', userID);
          if (examEl && examEl.value) localStorage.setItem('ara_last_exam_id', examID);
          if (classEl && classEl.value) localStorage.setItem('ara_last_class_id', classID);
          if (respEl && respEl.value) localStorage.setItem('ara_last_response_id', responseID);
          if (baseUrl) localStorage.setItem('ara_last_base_url', baseUrl);

          var ctx = {
            baseUrl: baseUrl || localStorage.getItem('ara_last_base_url') || '',
            userID: userID,
            examID: examID,
            classID: classID,
            responseID: responseID
          };
          var sig = JSON.stringify(ctx);
          if (sig !== lastContextSignature) {
            lastContextSignature = sig;
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('onExamContextUpdate', ctx);
            }
          }
          return ctx;
        } catch (_) {
          return {};
        }
      }

      // Global bridge called by ARA Desktop/Mobile native KioskSecurityService when a violation occurs
      window.recordAraDesktopViolation = function(violationType, violationLabel, description, source) {
        try {
          if (typeof window.recordAraViolation === 'function') {
            window.recordAraViolation(
              violationType || 'app_exit',
              violationLabel || 'Keluar dari Aplikasi',
              description || '',
              source || 'ara_desktop',
              5000
            );
            return true;
          }
          var ctx = syncExamContextFromDOM();
          var baseUrl = ctx.baseUrl || resolvePortalBaseUrl();
          if (!baseUrl) return false;

          var formData = new URLSearchParams();
          if (ctx.userID) formData.append('userID', ctx.userID);
          if (ctx.examID) formData.append('examID', ctx.examID);
          if (ctx.classID) formData.append('classID', ctx.classID);
          if (ctx.responseID) formData.append('responseID', ctx.responseID);
          formData.append('violation_type', violationType || 'app_exit');
          formData.append('violation_label', violationLabel || 'Keluar dari Aplikasi');
          formData.append('description', description || '');
          formData.append('source', source || 'ara_desktop');
          formData.append('platform', navigator.userAgent || 'ara_desktop');

          fetch(baseUrl.replace(/\\/\$/, '') + '/Violation/record', {
            method: 'POST',
            headers: {
              'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
              'X-Requested-With': 'XMLHttpRequest'
            },
            body: formData.toString(),
            credentials: 'same-origin',
            keepalive: true
          }).catch(function() {});
          return true;
        } catch (_) {
          return false;
        }
      };

      // Prevent browser-level history back navigation (popstate guard)
      try {
        history.pushState(null, document.title, location.href);
        window.addEventListener('popstate', function() {
          history.pushState(null, document.title, location.href);
        });
      } catch (_) {}

      // Listen for emergency dev keys, supervisor panel, and block browser back shortcuts
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
        // Block Alt+Left / Alt+Right browser back/forward shortcuts
        if (e.altKey && (e.key === 'ArrowLeft' || e.key === 'ArrowRight' || e.keyCode === 37 || e.keyCode === 39)) {
          e.preventDefault();
          e.stopPropagation();
          return false;
        }
        // Block Backspace from triggering browser back when not inside a text input
        if (e.key === 'Backspace' || e.keyCode === 8) {
          var el = document.activeElement;
          var tag = el ? el.tagName.toUpperCase() : '';
          var isEditable = (tag === 'INPUT' || tag === 'TEXTAREA' || (el && el.isContentEditable));
          if (!isEditable) {
            e.preventDefault();
            e.stopPropagation();
            return false;
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
        syncExamContextFromDOM();
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

        if (isExam || isEssayRoute) {
          reportMode('exam');
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
      handlerName: 'onExamContextUpdate',
      callback: (args) {
        if (args.isNotEmpty && args[0] is Map) {
          final map = Map<String, dynamic>.from(args[0] as Map);
          map.forEach((key, value) {
            if (value != null && value.toString().isNotEmpty) {
              lastExamContext[key] = value.toString();
            }
          });
          debugPrint('[AssessmentDetector] Updated exam context: $lastExamContext');
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
        path == '/new_ara' ||
        path == '/new_ara/' ||
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

    // 2. Unified Exam routes (ujian / exam / soal / essay / esai / uraian / test / cbt / quiz / mulai / kerjakan)
    if (path.contains('/ujian') ||
        path.contains('/exam') ||
        path.contains('/soal') ||
        path.contains('/essay') ||
        path.contains('/esai') ||
        path.contains('/uraian') ||
        path.contains('/test') ||
        path.contains('/cbt') ||
        path.contains('/quiz') ||
        path.contains('/mulai') ||
        path.contains('/kerjakan') ||
        path.contains('/start')) {
      _kioskService.setMode(AssessmentMode.exam);
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
      case 'essay':
        _kioskService.setMode(AssessmentMode.exam);
        break;
      case 'normal':
      case 'idle':
      default:
        _kioskService.setMode(AssessmentMode.normal);
        break;
    }
  }
}
