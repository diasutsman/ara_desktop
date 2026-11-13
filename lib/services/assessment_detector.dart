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

  /// Callback when the page DOM is ready (interactive/complete) with the current URL
  ValueChanged<String>? onDomReady;

  /// Callback when an Office document or Office URI scheme link is clicked inside the page
  ValueChanged<String>? onExternalOrOfficeUrlRequested;

  /// Latest user/exam context reported by the WebView DOM
  final Map<String, String> lastExamContext = {};

  // JavaScript snippet injected into every web page loaded
  static const String injectedScript = """
    (function() {
      // 1. Apple WKWebView compatibility guards for MediaRecorder & getDisplayMedia:
      // - Prevents macOS WKWebView from popping up a blocking native OS screen-sharing
      //   picker modal sheet during Kiosk mode when startScreenRecordingLite() runs,
      //   while keeping camera proctoring (getUserMedia) 100% active.
      // - Normalizes unsupported "video/webm;codecs=vp8" mimeType on Apple WebKit.
      try {
        var ua = navigator.userAgent || '';
        var isAppleWebKit = /Macintosh|Mac OS X|iPhone|iPad|iPod/i.test(ua) &&
                            typeof window.webkit !== 'undefined';
        if (isAppleWebKit && navigator.mediaDevices && typeof navigator.mediaDevices.getDisplayMedia === 'function') {
          navigator.mediaDevices.getDisplayMedia = function() {
            return Promise.reject(new DOMException('Screen recording is managed by ARA Desktop Kiosk.', 'NotAllowedError'));
          };
        }
        if (typeof window.MediaRecorder === 'function') {
          var OriginalMediaRecorder = window.MediaRecorder;
          var PatchedMediaRecorder = function(stream, options) {
            var safeOptions = options;
            try {
              if (options && options.mimeType && typeof OriginalMediaRecorder.isTypeSupported === 'function') {
                if (!OriginalMediaRecorder.isTypeSupported(options.mimeType)) {
                  safeOptions = Object.assign({}, options);
                  delete safeOptions.mimeType;
                }
              }
            } catch (_) {}
            return new OriginalMediaRecorder(stream, safeOptions);
          };
          PatchedMediaRecorder.prototype = OriginalMediaRecorder.prototype;
          if (typeof OriginalMediaRecorder.isTypeSupported === 'function') {
            PatchedMediaRecorder.isTypeSupported = OriginalMediaRecorder.isTypeSupported.bind(OriginalMediaRecorder);
          }
          window.MediaRecorder = PatchedMediaRecorder;
        }
      } catch (_) {}

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

        // Check if on Landing, Login, Register, Dashboard, Profile, or Verification pages (Normal mode)
        var isNormal = pathname === '' ||
                       pathname === '/' ||
                       pathname === '/assess' ||
                       pathname === '/assess/' ||
                       pathname.indexOf('/login') !== -1 ||
                       pathname.indexOf('/register') !== -1 ||
                       pathname.indexOf('/dashboard') !== -1 ||
                       pathname.indexOf('/profile') !== -1 ||
                       pathname.indexOf('/user') !== -1 ||
                       pathname.indexOf('/biodata') !== -1 ||
                       pathname.indexOf('/verifikasi') !== -1 ||
                       pathname.indexOf('/verification') !== -1 ||
                       pathname.indexOf('/step') !== -1 ||
                       pathname.indexOf('/instruksi') !== -1 ||
                       pathname.indexOf('/instruction') !== -1 ||
                       pathname.indexOf('/jadwal') !== -1 ||
                       pathname.indexOf('/schedule') !== -1 ||
                       pathname.indexOf('/password') !== -1 ||
                       pathname.indexOf('/log') !== -1 ||
                       pathname.indexOf('/account') !== -1 ||
                       pathname.indexOf('/home') !== -1 ||
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

        if (isExam || isEssayRoute || hasEssayEditor) {
          reportMode('exam');
        } else {
          // Default to normal mode when not in an active exam session
          reportMode('normal');
        }
      }

      var hasReportedDomReady = false;
      function notifyDomReady() {
        try {
          var href = window.location.href || '';
          if (href && href !== 'about:blank' && (document.readyState === 'interactive' || document.readyState === 'complete')) {
            if (!hasReportedDomReady && window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              hasReportedDomReady = true;
              window.flutter_inappwebview.callHandler('onDomReady', href);
            }
          }
        } catch (_) {}
      }

      // Intercept window.alert() with an in-page DOM modal so the OK button is
      // always clickable across Windows WebView2 (offscreen texture), macOS, and mobile.
      if (!window.__araAlertPatched) {
        window.__araAlertPatched = true;
        var _nativeAlert = window.alert ? window.alert.bind(window) : null;
        window.alert = function(msg) {
          try {
            var text = (msg === undefined || msg === null) ? '' : String(msg);
            var existing = document.getElementById('ara-inpage-alert-overlay');
            if (existing && existing.parentNode) {
              existing.parentNode.removeChild(existing);
            }
            var overlay = document.createElement('div');
            overlay.id = 'ara-inpage-alert-overlay';
            overlay.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:rgba(0,0,0,0.45);display:flex;align-items:center;justify-content:center;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;';

            var box = document.createElement('div');
            box.style.cssText = 'background:#ffffff;color:#1f2937;border-radius:12px;box-shadow:0 20px 45px rgba(0,0,0,0.28);max-width:440px;width:90%;padding:22px 24px;box-sizing:border-box;';

            var header = document.createElement('div');
            header.style.cssText = 'font-size:13px;font-weight:600;color:#6b7280;margin-bottom:8px;';
            header.textContent = 'ara-assessment.com';

            var body = document.createElement('div');
            body.style.cssText = 'font-size:15px;line-height:1.5;color:#111827;margin-bottom:20px;white-space:pre-wrap;word-break:break-word;';
            body.textContent = text;

            var footer = document.createElement('div');
            footer.style.cssText = 'display:flex;justify-content:flex-end;';

            var btn = document.createElement('button');
            btn.type = 'button';
            btn.textContent = 'OK';
            btn.style.cssText = 'background:#0078d4;color:#ffffff;border:none;border-radius:6px;padding:8px 22px;font-size:14px;font-weight:600;cursor:pointer;outline:none;';

            var closeModal = function() {
              if (overlay && overlay.parentNode) {
                overlay.parentNode.removeChild(overlay);
              }
              document.removeEventListener('keydown', onKeyDown, true);
            };
            var onKeyDown = function(ev) {
              if (ev.key === 'Enter' || ev.key === 'Escape' || ev.key === ' ') {
                ev.preventDefault();
                closeModal();
              }
            };
            btn.addEventListener('click', closeModal);
            document.addEventListener('keydown', onKeyDown, true);

            footer.appendChild(btn);
            box.appendChild(header);
            box.appendChild(body);
            box.appendChild(footer);
            overlay.appendChild(box);
            (document.body || document.documentElement).appendChild(overlay);
            setTimeout(function() { try { btn.focus(); } catch (_) {} }, 20);
          } catch (_) {
            if (_nativeAlert) _nativeAlert(msg);
          }
        };
      }

      // Intercept clicks on Office document links or ms-word/ms-excel/ms-powerpoint schemes
      document.addEventListener('click', function(e) {
        try {
          var target = e.target;
          while (target && target !== document && (!target.tagName || target.tagName.toUpperCase() !== 'A')) {
            target = target.parentNode;
          }
          if (!target || !target.href) return;
          var href = String(target.href).trim();
          if (!href) return;
          var lower = href.toLowerCase();
          var isOfficeScheme = lower.indexOf('ms-word:') === 0 ||
                               lower.indexOf('ms-excel:') === 0 ||
                               lower.indexOf('ms-powerpoint:') === 0 ||
                               lower.indexOf('ms-office:') === 0;
          var cleanPath = lower.split('?')[0].split('#')[0];
          var isOfficeExt = cleanPath.endsWith('.doc') ||
                            cleanPath.endsWith('.docx') ||
                            cleanPath.endsWith('.xls') ||
                            cleanPath.endsWith('.xlsx') ||
                            cleanPath.endsWith('.ppt') ||
                            cleanPath.endsWith('.pptx');
          if (isOfficeScheme || isOfficeExt) {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              e.preventDefault();
              e.stopPropagation();
              window.flutter_inappwebview.callHandler('onExternalOrOfficeUrl', href);
            }
          }
        } catch (_) {}
      }, true);

      // Run detection when DOM is loaded and periodically every 2 seconds
      document.addEventListener('DOMContentLoaded', function() {
        notifyDomReady();
        detectStateFromDOM();
      });
      window.addEventListener('load', function() {
        notifyDomReady();
        detectStateFromDOM();
      });
      if (document.readyState === 'interactive' || document.readyState === 'complete') {
        setTimeout(function() {
          notifyDomReady();
          detectStateFromDOM();
        }, 50);
      }
      setInterval(function() {
        notifyDomReady();
        detectStateFromDOM();
      }, 2000);
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

    controller.addJavaScriptHandler(
      handlerName: 'onDomReady',
      callback: (args) {
        final url = args.isNotEmpty ? (args[0]?.toString() ?? '') : '';
        debugPrint('[AssessmentDetector] JS reported DOM ready for URL: $url');
        onDomReady?.call(url);
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'onExternalOrOfficeUrl',
      callback: (args) {
        final url = args.isNotEmpty ? (args[0]?.toString() ?? '') : '';
        if (url.isNotEmpty) {
          debugPrint('[AssessmentDetector] JS intercepted Office/external URL: $url');
          onExternalOrOfficeUrlRequested?.call(url);
        }
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

    // 1. Normal / Landing / Login / Dashboard / Profile / Verification / Finished
    if (path == '' ||
        path == '/' ||
        path == '/new_ara' ||
        path == '/new_ara/' ||
        path == '/assess' ||
        path == '/assess/' ||
        path.contains('/login') ||
        path.contains('/register') ||
        path.contains('/dashboard') ||
        path.contains('/profile') ||
        path.contains('/user') ||
        path.contains('/biodata') ||
        path.contains('/verifikasi') ||
        path.contains('/verification') ||
        path.contains('/step') ||
        path.contains('/instruksi') ||
        path.contains('/instruction') ||
        path.contains('/jadwal') ||
        path.contains('/schedule') ||
        path.contains('/password') ||
        path.contains('/log') ||
        path.contains('/pelanggaran') ||
        path.contains('/account') ||
        path.contains('/home') ||
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

    // 3. Safe fallback: Non-exam routes restore normal mode if currently in exam
    if (_kioskService.currentMode != AssessmentMode.normal) {
      _kioskService.setMode(AssessmentMode.normal);
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
