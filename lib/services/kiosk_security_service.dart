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

enum WindowAction {
  allow,
  block,
}

class SecurityPolicyEvaluation {
  final WindowAction action;
  final String reason;

  const SecurityPolicyEvaluation(this.action, [this.reason = '']);
  bool get isBlocked => action == WindowAction.block;
  bool get isAllowed => action == WindowAction.allow;
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

  // Allowed executables during development (case-insensitive) - Tools only, NO browsers!
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
    'startmenuexperiencehost.exe',
    'ctfmon.exe',
  };

  // Legitimate Windows OS Shell classes that may be active during desktop/taskbar interaction
  static final Set<String> allowedShellClasses = {
    'Shell_TrayWnd',
    'Shell_SecondaryTrayWnd',
    'Progman',
    'WorkerW',
    'Windows.UI.Core.CoreWindow',
    'TextInputHost',
    'StartMenuExperienceHost',
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

  Future<void> _setWindowLock(bool locked) async {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      await _kioskHookChannel.invokeMethod('setWindowLock', {'locked': locked});
      debugPrint('[KioskSecurityService] Win32 Window Controls Lock set to: $locked');
    } catch (e) {
      debugPrint('[KioskSecurityService] Error invoking setWindowLock: $e');
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
    await _setWindowLock(false);
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
        await _setWindowLock(false);
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
        await _setWindowLock(true);
        await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
        await windowManager.setResizable(false);
        await windowManager.setMinimizable(false);
        await windowManager.setMaximizable(false);
        await windowManager.setFullScreen(true);
        await windowManager.setAlwaysOnTop(true);
      } else if (_currentMode == AssessmentMode.essayExam) {
        await _setKioskHook(false);
        await _setWindowLock(true);
        await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
        await windowManager.setResizable(false);
        await windowManager.setMinimizable(false);
        await windowManager.setMaximizable(false);
        await windowManager.setFullScreen(false);
        await windowManager.maximize();
        await windowManager.setAlwaysOnTop(false);
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
          await _setWindowLock(false);
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
            await _setWindowLock(true);
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
          // In essay exam:
          // 1. Unhook Alt+Tab to allow switching between ARA, Word, and PowerPoint
          await _setKioskHook(false);
          // 2. Lock window controls so ARA cannot be closed, minimized, or resized
          await _setWindowLock(true);
          if (!devBypassLockdown) {
            await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
            await windowManager.setResizable(false);
            await windowManager.setMinimizable(false);
            await windowManager.setMaximizable(false);
            // Show taskbar: NOT fullscreen, but MAXIMIZED!
            if (await windowManager.isFullScreen()) {
              await windowManager.setFullScreen(false);
            }
            await windowManager.maximize();
            // Don't stay on top so Word and PowerPoint can appear over ARA
            await windowManager.setAlwaysOnTop(false);
          }
          await windowManager.setPreventClose(!isDevMode || !devBypassLockdown);
          _startWatchdog();
          break;
      }
    }
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    if (kIsWeb || !Platform.isWindows) return;

    // Check foreground application every 200ms for fast detection
    _watchdogTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
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
      final isOwnProcess = (activePid == _ownProcessId || activePid == 0);
      if (isOwnProcess) {
        return;
      }

      final processExe = _getProcessExecutable(activePid).toLowerCase();
      final className = _getWindowClassName(hwnd);
      final windowTitle = _getWindowTitle(hwnd);

      final evaluation = evaluateWindowPolicy(
        mode: _currentMode,
        processExe: processExe,
        className: className,
        windowTitle: windowTitle,
        isOwnProcess: isOwnProcess,
        isDevBypass: devBypassLockdown,
      );

      if (evaluation.isBlocked) {
        final displayName = processExe.isNotEmpty
            ? processExe
            : (windowTitle.isNotEmpty ? windowTitle : (className.isNotEmpty ? className : 'Aplikasi Sistem Terproteksi'));
        _blockUnauthorizedWindow(hwnd, displayName, evaluation.reason);
      }
    } catch (e) {
      debugPrint('[KioskSecurityService] Error checking foreground window: $e');
    }
  }

  String _getWindowClassName(HWND hwnd) {
    if (hwnd.address == 0) return '';
    final buffer = wsalloc(256);
    try {
      final res = GetClassName(hwnd, buffer, 256);
      return res.value > 0 ? buffer.toDartString() : '';
    } catch (_) {
      return '';
    } finally {
      calloc.free(buffer);
    }
  }

  String _getWindowTitle(HWND hwnd) {
    if (hwnd.address == 0) return '';
    final buffer = wsalloc(256);
    try {
      final res = GetWindowText(hwnd, buffer, 256);
      return res.value > 0 ? buffer.toDartString() : '';
    } catch (_) {
      return '';
    } finally {
      calloc.free(buffer);
    }
  }

  SecurityPolicyEvaluation evaluateWindowPolicy({
    required AssessmentMode mode,
    required String processExe,
    required String className,
    required String windowTitle,
    required bool isOwnProcess,
    required bool isDevBypass,
  }) {
    if (isOwnProcess) {
      return const SecurityPolicyEvaluation(WindowAction.allow, 'Own process');
    }

    final lowerExe = processExe.toLowerCase();

    if (isDevMode && isDevBypass && _devWhitelist.contains(lowerExe)) {
      return const SecurityPolicyEvaluation(WindowAction.allow, 'Dev whitelist bypass');
    }

    // 1. Handle Empty Executable (Elevated/Admin Processes like Device Manager, Regedit, MMC)
    if (lowerExe.isEmpty) {
      // Only permit legitimate Windows OS shell desktop/taskbar classes
      if (allowedShellClasses.contains(className)) {
        return const SecurityPolicyEvaluation(WindowAction.allow, 'System shell infrastructure');
      }
      return SecurityPolicyEvaluation(
        WindowAction.block,
        'Aplikasi sistem atau elevated ($className) diblokir! Aplikasi dengan hak administrator tidak diizinkan selama ujian.',
      );
    }

    // 2. Strict Mode: NO other app is permitted
    if (mode == AssessmentMode.strictExam) {
      return SecurityPolicyEvaluation(
        WindowAction.block,
        'Aplikasi "$lowerExe" diblokir! Selama sesi ujian ketat, Anda tidak diizinkan membuka aplikasi lain.',
      );
    }

    // 3. Essay Mode: Word, PowerPoint, and system shell permitted
    if (mode == AssessmentMode.essayExam) {
      // Handle explorer.exe: Distinguish Taskbar/Desktop vs File Explorer (CabinetWClass) and Run dialog
      if (lowerExe == 'explorer.exe') {
        if (className == 'CabinetWClass' || className == 'ExploreWClass') {
          return const SecurityPolicyEvaluation(
            WindowAction.block,
            'File Explorer diblokir! Anda tidak diizinkan membuka folder/file selama sesi essay.',
          );
        }
        if (className == '#32770' &&
            (windowTitle.toLowerCase().contains('run') || windowTitle.toLowerCase().contains('jalankan'))) {
          return const SecurityPolicyEvaluation(
            WindowAction.block,
            'Kotak dialog Run diblokir selama sesi ujian!',
          );
        }
        return const SecurityPolicyEvaluation(WindowAction.allow, 'Windows shell infrastructure');
      }

      final isWhitelisted = _essayWhitelist.contains(lowerExe);
      if (isWhitelisted) {
        return const SecurityPolicyEvaluation(WindowAction.allow, 'Essay whitelist');
      }

      return SecurityPolicyEvaluation(
        WindowAction.block,
        'Aplikasi "$lowerExe" diblokir! Pada sesi essay, hanya Microsoft Word dan PowerPoint yang diizinkan.',
      );
    }

    return const SecurityPolicyEvaluation(WindowAction.allow, 'Normal mode');
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
    if (isDevMode && devBypassLockdown && _devWhitelist.contains(exeName.toLowerCase())) {
      return;
    }

    debugPrint('[KioskSecurityService] Unauthorized app detected: $exeName. Minimizing and seizing foreground for ARA...');

    // 1. Double-action minimize: PostMessage WM_SYSCOMMAND SC_MINIMIZE for UWP ApplicationFrameHost & ShowWindow SW_MINIMIZE
    try {
      PostMessage(hwnd, WM_SYSCOMMAND, const WPARAM(SC_MINIMIZE), const LPARAM(0));
      ShowWindow(hwnd, SW_MINIMIZE);
    } catch (e) {
      debugPrint('[KioskSecurityService] Error minimizing unauthorized window: $e');
    }

    // 2. Seize foreground focus back to ARA using native Win32 (AttachThreadInput + SetWindowPos)
    try {
      _kioskHookChannel.invokeMethod('forceForeground');
    } catch (e) {
      debugPrint('[KioskSecurityService] Error invoking native forceForeground: $e');
    }

    // 3. Fallback windowManager focus
    windowManager.focus();

    // 4. Trigger UI warning alert
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
