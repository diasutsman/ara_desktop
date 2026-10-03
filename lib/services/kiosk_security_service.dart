import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';
import 'package:window_manager/window_manager.dart';

enum AssessmentMode {
  normal,      // Browsing / Dashboard - No restrictions
  strictExam,  // Regular exam - Only ARA Assessment is allowed, all other apps minimized
  essayExam,   // Essay exam - ARA Assessment, MS Word, and MS PowerPoint allowed
}

class KioskSecurityService with WindowListener {
  static final KioskSecurityService _instance = KioskSecurityService._internal();
  factory KioskSecurityService() => _instance;
  KioskSecurityService._internal();

  AssessmentMode _currentMode = AssessmentMode.normal;
  AssessmentMode get currentMode => _currentMode;

  final ValueNotifier<AssessmentMode> modeNotifier = ValueNotifier<AssessmentMode>(AssessmentMode.normal);
  final ValueNotifier<String?> securityAlertNotifier = ValueNotifier<String?>(null);

  Timer? _watchdogTimer;
  int _ownProcessId = 0;

  // Allowed executables in essay mode (case-insensitive)
  final Set<String> _essayWhitelist = {
    'winword.exe',
    'powerpnt.exe',
    // Essential Windows OS components
    'explorer.exe',
    'dwm.exe',
    'taskhostw.exe',
    'textinputhost.exe',
    'shellexperiencehost.exe',
    'searchhost.exe',
    'ctfmon.exe',
  };

  Future<void> initialize() async {
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      windowManager.addListener(this);
      _ownProcessId = _getOwnProcessId();
    }
  }

  void dispose() {
    _watchdogTimer?.cancel();
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      windowManager.removeListener(this);
    }
  }

  int _getOwnProcessId() {
    if (kIsWeb || !Platform.isWindows) return 0;
    try {
      return GetCurrentProcessId();
    } catch (e) {
      debugPrint('[KioskSecurityService] Failed to get own PID: $e');
      return 0;
    }
  }

  Future<void> setMode(AssessmentMode mode) async {
    if (_currentMode == mode) return;
    _currentMode = mode;
    modeNotifier.value = mode;

    debugPrint('[KioskSecurityService] Switching mode to: $mode');

    if (kIsWeb) return;

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      switch (mode) {
        case AssessmentMode.normal:
          _stopWatchdog();
          await windowManager.setAlwaysOnTop(false);
          await windowManager.setFullScreen(false);
          await windowManager.setPreventClose(false);
          break;

        case AssessmentMode.strictExam:
          await windowManager.setFullScreen(true);
          await windowManager.setAlwaysOnTop(true);
          await windowManager.setPreventClose(true);
          await windowManager.focus();
          _startWatchdog();
          break;

        case AssessmentMode.essayExam:
          // In essay exam, allow user to view MS Word & PowerPoint alongside or over ARA
          await windowManager.setAlwaysOnTop(false);
          await windowManager.setPreventClose(true);
          _startWatchdog();
          break;
      }
    }
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    if (kIsWeb || !Platform.isWindows) return;

    // Check foreground application every 400ms
    _watchdogTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      _checkForegroundWindow();
    });
  }

  void _stopWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  void _checkForegroundWindow() {
    if (kIsWeb || !Platform.isWindows) return;
    if (_currentMode == AssessmentMode.normal) return;

    try {
      final hwnd = GetForegroundWindow();
      if (hwnd.address == 0) return;

      final pProcessId = calloc<DWORD>();
      GetWindowThreadProcessId(hwnd, pProcessId);
      final activePid = pProcessId.value;
      calloc.free(pProcessId);

      // If active process is our own application, everything is valid
      if (activePid == _ownProcessId || activePid == 0) {
        return;
      }

      final processExe = _getProcessExecutable(activePid).toLowerCase();
      if (processExe.isEmpty) return;

      if (_currentMode == AssessmentMode.strictExam) {
        // Strict Mode: NO other app is permitted
        _blockUnauthorizedWindow(hwnd, processExe,
            'Aplikasi "$processExe" diblokir! Selama sesi ujian, Anda tidak diizinkan membuka aplikasi lain.');
      } else if (_currentMode == AssessmentMode.essayExam) {
        // Essay Mode: Only MS Word and PowerPoint (and system UI) permitted
        final isWhitelisted = _essayWhitelist.contains(processExe);
        if (!isWhitelisted) {
          _blockUnauthorizedWindow(hwnd, processExe,
              'Aplikasi "$processExe" diblokir! Pada sesi essay, hanya Microsoft Word dan PowerPoint yang diizinkan.');
        }
      }
    } catch (e) {
      debugPrint('[KioskSecurityService] Error checking foreground window: $e');
    }
  }

  String _getProcessExecutable(int pid) {
    if (pid <= 0) return '';
    var processName = '';

    final openResult = OpenProcess(
      PROCESS_QUERY_LIMITED_INFORMATION,
      false,
      pid,
    );

    if (openResult.error == ERROR_SUCCESS) {
      final hProcess = openResult.value;
      final buffer = wsalloc(MAX_PATH);
      final size = calloc<DWORD>()..value = MAX_PATH;

      try {
        final queryResult = QueryFullProcessImageName(
          hProcess,
          PROCESS_NAME_WIN32,
          buffer,
          size,
        );
        if (queryResult.value) {
          final fullPath = buffer.toDartString();
          final parts = fullPath.split(Platform.pathSeparator);
          processName = parts.isNotEmpty ? parts.last : fullPath;
        }
      } finally {
        calloc.free(buffer);
        calloc.free(size);
        CloseHandle(hProcess);
      }
    }
    return processName;
  }

  void _blockUnauthorizedWindow(HWND hwnd, String exeName, String alertMessage) {
    debugPrint('[KioskSecurityService] Unauthorized app detected: $exeName. Minimizing...');

    // Minimize the unauthorized window
    ShowWindow(hwnd, SW_MINIMIZE);

    // Refocus our ARA application
    if (_currentMode == AssessmentMode.strictExam) {
      windowManager.focus();
      windowManager.setAlwaysOnTop(true);
    }

    // Trigger UI warning alert
    securityAlertNotifier.value = alertMessage;

    // Auto clear alert banner after 3 seconds
    Timer(const Duration(seconds: 3), () {
      if (securityAlertNotifier.value == alertMessage) {
        securityAlertNotifier.value = null;
      }
    });
  }

  @override
  void onWindowBlur() {
    if (_currentMode == AssessmentMode.strictExam) {
      // In strict exam mode, refocus immediately if window loses focus
      windowManager.focus();
    }
  }

  @override
  void onWindowClose() async {
    if (_currentMode != AssessmentMode.normal) {
      securityAlertNotifier.value = 'Ujian sedang berlangsung! Aplikasi tidak dapat ditutup.';
      Timer(const Duration(seconds: 3), () {
        securityAlertNotifier.value = null;
      });
    } else {
      await windowManager.destroy();
    }
  }
}
