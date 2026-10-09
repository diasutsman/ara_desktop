import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

  static const MethodChannel _kioskHookChannel = MethodChannel('ara_desktop/kiosk_hook');

  AssessmentMode _currentMode = AssessmentMode.normal;
  AssessmentMode get currentMode => _currentMode;

  final ValueNotifier<AssessmentMode> modeNotifier = ValueNotifier<AssessmentMode>(AssessmentMode.normal);
  final ValueNotifier<String?> securityAlertNotifier = ValueNotifier<String?>(null);

  bool isManualOverride = false;
  final ValueNotifier<bool> manualOverrideNotifier = ValueNotifier<bool>(false);

  Timer? _watchdogTimer;
  int _ownProcessId = 0;

  bool isDevMode = kDebugMode;
  bool devBypassLockdown = false;

  Future<void> setManualMode(AssessmentMode mode) async {
    isManualOverride = true;
    manualOverrideNotifier.value = true;
    debugPrint('[KioskSecurityService] Manual Mode Lock engaged: $mode');
    await setMode(mode);
  }

  void clearManualOverride() {
    isManualOverride = false;
    manualOverrideNotifier.value = false;
    debugPrint('[KioskSecurityService] Manual Mode Lock cleared. Auto-detection resumed.');
  }

  // Allowed executables during development (case-insensitive)
  static final Set<String> _devWhitelist = {
    'taskmgr.exe',
    'code.exe',
    'cursor.exe',
    'idea64.exe',
    'devenv.exe',
    'cmd.exe',
    'powershell.exe',
    'pwsh.exe',
    'windowsterminal.exe',
    'wt.exe',
    'dart.exe',
    'flutter.exe',
    'chrome.exe',
    'msedge.exe',
    'firefox.exe',
  };

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

  Future<void> _setKioskHook(bool enabled) async {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      await _kioskHookChannel.invokeMethod('setHook', {'enabled': enabled});
      debugPrint('[KioskSecurityService] Win32 WH_KEYBOARD_LL hook set to: $enabled');
    } catch (e) {
      debugPrint('[KioskSecurityService] Error invoking kiosk hook: $e');
    }
  }

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

  Future<void> exitApp() async {
    debugPrint('[KioskSecurityService] Exiting application cleanly...');
    _stopWatchdog();
    await _setKioskHook(false);
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      try {
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        await windowManager.setResizable(true);
        await windowManager.setMinimizable(true);
        await windowManager.setMaximizable(true);
        await windowManager.setPreventClose(false);
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setFullScreen(false);
        await windowManager.destroy();
      } catch (e) {
        debugPrint('[KioskSecurityService] Error during exit cleanup: $e');
      }
    }
    exit(0);
  }

  Future<void> toggleDevBypassLockdown() async {
    devBypassLockdown = !devBypassLockdown;
    debugPrint('[KioskSecurityService] devBypassLockdown is now: $devBypassLockdown');
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      if (devBypassLockdown) {
        await _setKioskHook(false);
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        await windowManager.setResizable(true);
        await windowManager.setMinimizable(true);
        await windowManager.setMaximizable(true);
        if (await windowManager.isFullScreen()) {
          await windowManager.setFullScreen(false);
        }
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setPreventClose(false);
      } else if (_currentMode == AssessmentMode.strictExam) {
        await _setKioskHook(true);
        await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
        await windowManager.setResizable(false);
        await windowManager.setMinimizable(false);
        await windowManager.setMaximizable(false);
        await windowManager.setFullScreen(true);
        await windowManager.setAlwaysOnTop(true);
      }
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

    debugPrint('[KioskSecurityService] Switching mode to: $mode (isDevMode: $isDevMode, devBypass: $devBypassLockdown)');

    if (kIsWeb) return;

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      switch (mode) {
        case AssessmentMode.normal:
          await _setKioskHook(false);
          _stopWatchdog();
          await windowManager.setTitleBarStyle(TitleBarStyle.normal);
          await windowManager.setResizable(true);
          await windowManager.setMinimizable(true);
          await windowManager.setMaximizable(true);
          await windowManager.setAlwaysOnTop(false);
          if (await windowManager.isFullScreen()) {
            await windowManager.setFullScreen(false);
          }
          await windowManager.setPreventClose(false);
          break;

        case AssessmentMode.strictExam:
          if (!devBypassLockdown) {
            await _setKioskHook(true);
            await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
            await windowManager.setResizable(false);
            await windowManager.setMinimizable(false);
            await windowManager.setMaximizable(false);
            await windowManager.setFullScreen(true);
            await windowManager.setAlwaysOnTop(true);
          }
          await windowManager.setPreventClose(!isDevMode || !devBypassLockdown);
          await windowManager.focus();
          _startWatchdog();
          break;

        case AssessmentMode.essayExam:
          // In essay exam, unhook Alt+Tab to allow switching between ARA, Word, and PowerPoint
          await _setKioskHook(false);
          if (!devBypassLockdown) {
            await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
            await windowManager.setResizable(false);
            await windowManager.setMinimizable(true);
            await windowManager.setMaximizable(false);
            await windowManager.setFullScreen(true);
          }
          await windowManager.setAlwaysOnTop(false);
          await windowManager.setPreventClose(!isDevMode || !devBypassLockdown);
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

      if (isDevMode && _devWhitelist.contains(processExe)) {
        // Developer tools, terminal, IDE, and Task Manager are permitted during development
        return;
      }

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
    if (isDevMode && _devWhitelist.contains(exeName)) {
      return;
    }

    debugPrint('[KioskSecurityService] Unauthorized app detected: $exeName. Minimizing...');

    // Minimize the unauthorized window
    ShowWindow(hwnd, SW_MINIMIZE);

    // Refocus our ARA application (only if not in dev mode)
    if (_currentMode == AssessmentMode.strictExam && !isDevMode) {
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
    if (_currentMode == AssessmentMode.strictExam && !devBypassLockdown) {
      // In strict exam mode, refocus immediately if window loses focus
      windowManager.focus();
      windowManager.setAlwaysOnTop(true);
    }
  }

  @override
  void onWindowClose() async {
    if (isDevMode) {
      debugPrint('[KioskSecurityService] Dev mode: Window close requested, exiting cleanly.');
      await exitApp();
      return;
    }

    if (_currentMode != AssessmentMode.normal) {
      securityAlertNotifier.value = 'Ujian sedang berlangsung! Aplikasi tidak dapat ditutup.';
      Timer(const Duration(seconds: 3), () {
        securityAlertNotifier.value = null;
      });
    } else {
      await exitApp();
    }
  }
}
