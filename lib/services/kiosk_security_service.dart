import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:win32/win32.dart';
import 'package:window_manager/window_manager.dart';

enum AssessmentMode {
  normal,      // Browsing / Dashboard - No restrictions
  exam,        // Unified exam mode - ARA Assessment, MS Word, Excel, and PowerPoint allowed
  strictExam,  // Alias/compatibility with exam
  essayExam,   // Alias/compatibility with exam
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
  static const MethodChannel _mobileChannel = MethodChannel('ara_desktop/mobile_kiosk');

  AssessmentMode _currentMode = AssessmentMode.normal;
  AssessmentMode get currentMode => _currentMode;
  @visibleForTesting
  set currentMode(AssessmentMode mode) => _applyModeState(mode);

  /// Updates mode state shared by [setMode] and the test setter.
  /// Leaving the exam (back to Normal) also ends any authorized Office session.
  void _applyModeState(AssessmentMode mode) {
    _currentMode = mode;
    modeNotifier.value = mode;
    _hasRecordedCurrentPauseViolation = false;
    if (mode == AssessmentMode.normal && isOfficeSessionActive) {
      markOfficeSessionEnded();
    }
  }

  final ValueNotifier<AssessmentMode> modeNotifier = ValueNotifier<AssessmentMode>(AssessmentMode.normal);
  final ValueNotifier<String?> securityAlertNotifier = ValueNotifier<String?>(null);
  VoidCallback? onRefreshRequested;

  bool isManualOverride = false;
  final ValueNotifier<bool> manualOverrideNotifier = ValueNotifier<bool>(false);

  bool isOfficeSessionActive = false;
  int violationCount = 0;
  bool _hasRecordedCurrentPauseViolation = false;
  Timer? _alertClearTimer;

  void _showSecurityAlert(String message, {Duration duration = const Duration(seconds: 3)}) {
    securityAlertNotifier.value = message;
    _alertClearTimer?.cancel();
    _alertClearTimer = Timer(duration, () {
      if (securityAlertNotifier.value == message) {
        securityAlertNotifier.value = null;
      }
    });
  }

  void markOfficeSessionStarted() {
    isOfficeSessionActive = true;
    debugPrint('[KioskSecurityService] Office Session Started - App switching allowed for Office.');
    _syncMobileOfficeSession(true);
  }

  void markOfficeSessionEnded() {
    isOfficeSessionActive = false;
    debugPrint('[KioskSecurityService] Office Session Ended.');
    _syncMobileOfficeSession(false);
  }

  void _syncMobileOfficeSession(bool active) {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    _mobileChannel.invokeMethod('setOfficeSession', {'active': active}).catchError((Object e) {
      debugPrint('[KioskSecurityService] Failed to sync Office session to mobile native: $e');
    });
  }

  Future<void> setPermissionRequestInProgress(bool active) async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    try {
      await _mobileChannel.invokeMethod('setPermissionRequestInProgress', {'active': active});
    } catch (e) {
      debugPrint('[KioskSecurityService] Failed to setPermissionRequestInProgress: $e');
    }
  }

  void handleAppLifecycleChange(AppLifecycleState state) {
    if (_currentMode == AssessmentMode.normal) return;

    if (state == AppLifecycleState.resumed) {
      // The Office session intentionally persists for the whole exam so the participant can
      // switch back and forth between ARA and Word/Excel/PowerPoint (parity with desktop Alt+Tab).
      // It is cleared only when the mode returns to Normal (see _applyModeState).
      _hasRecordedCurrentPauseViolation = false;
      debugPrint('[KioskSecurityService] App resumed (officeSessionActive: $isOfficeSessionActive).');
      _reapplyMobileImmersiveMode();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      debugPrint('[KioskSecurityService] App paused/hidden.');
      if (!isOfficeSessionActive && !devBypassLockdown && !_hasRecordedCurrentPauseViolation) {
        _hasRecordedCurrentPauseViolation = true;
        violationCount++;
        final msg = 'PERINGATAN: Anda terdeteksi meninggalkan aplikasi ARA Assessment saat ujian! (Pelanggaran ke-$violationCount)';
        debugPrint('[KioskSecurityService] $msg');
        _showSecurityAlert(msg, duration: const Duration(seconds: 4));
      }
    }
  }

  /// Handles blocked navigation/system events reported by native Android (`MainActivity.kt`)
  /// and iOS (`AppDelegate.swift`).
  void handleMobileBlockedNavigation(String reason) {
    if (devBypassLockdown || _currentMode == AssessmentMode.normal) return;

    switch (reason) {
      case 'back':
        const msg = 'PERINGATAN: Tombol kembali (Back) dinonaktifkan! Anda tidak dapat kembali atau keluar dari aplikasi.';
        debugPrint('[KioskSecurityService] $msg');
        _showSecurityAlert(msg);
        break;

      case 'minimize':
        if (!isOfficeSessionActive) {
          if (!_hasRecordedCurrentPauseViolation) {
            _hasRecordedCurrentPauseViolation = true;
            violationCount++;
          }
          final msg =
              'PERINGATAN: Anda terdeteksi meninggalkan aplikasi ARA Assessment saat ujian! Tombol Minimize / Home diblokir. (Pelanggaran ke-$violationCount)';
          debugPrint('[KioskSecurityService] $msg');
          _showSecurityAlert(msg, duration: const Duration(seconds: 4));
        }
        break;

      case 'multi_window':
        violationCount++;
        final msg =
            'PERINGATAN: Mode Split-Screen / Multi-Window dilarang selama ujian! (Pelanggaran ke-$violationCount)';
        debugPrint('[KioskSecurityService] $msg');
        _showSecurityAlert(msg, duration: const Duration(seconds: 4));
        break;

      case 'screenshot':
        violationCount++;
        final msg =
            'PERINGATAN: Tangkapan layar (Screenshot) dilarang selama sesi ujian! (Pelanggaran ke-$violationCount)';
        debugPrint('[KioskSecurityService] $msg');
        _showSecurityAlert(msg, duration: const Duration(seconds: 4));
        break;

      case 'screen_capture':
        violationCount++;
        final msg =
            'PERINGATAN: Perekaman layar / Screen Mirroring dilarang selama sesi ujian! (Pelanggaran ke-$violationCount)';
        debugPrint('[KioskSecurityService] $msg');
        _showSecurityAlert(msg, duration: const Duration(seconds: 4));
        break;
    }
  }

  /// Android/iOS may restore the system bars after returning from another app (e.g. Word).
  void _reapplyMobileImmersiveMode() {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    if (devBypassLockdown || _currentMode == AssessmentMode.normal) return;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky).catchError((Object e) {
      debugPrint('[KioskSecurityService] Failed to re-apply immersive mode: $e');
    });
    _mobileChannel.invokeMethod('setKioskLockdown', {'enabled': true}).catchError((Object e) {
      debugPrint('[KioskSecurityService] Failed to re-apply native kiosk lockdown: $e');
    });
  }

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

  // Allowed executables in essay / utilities mode (case-insensitive)
  final Set<String> _essayWhitelist = {
    'winword.exe',
    'excel.exe',
    'powerpnt.exe',
    'wps.exe',
    'et.exe',
    'wpp.exe',
    'soffice.exe',
    'soffice.bin',
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

      // Listen for native Win32 menu commands from C++ runner
      _kioskHookChannel.setMethodCallHandler((call) async {
        if (call.method == 'onOfficeLaunched') {
          final app = call.arguments?.toString() ?? 'office';
          debugPrint('[KioskSecurityService] Office launched: $app');
          if (_currentMode != AssessmentMode.normal) {
            markOfficeSessionStarted();
          }
        } else if (call.method == 'onRefreshRequested') {
          debugPrint('[KioskSecurityService] Native Win32 Menu triggered refresh');
          onRefreshRequested?.call();
        }
      });
    } else if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      _mobileChannel.setMethodCallHandler((call) async {
        if (call.method == 'onNavigationBlocked') {
          final args = call.arguments;
          String reason = 'back';
          if (args is Map) {
            reason = args['reason']?.toString() ?? 'back';
          } else if (args is String) {
            reason = args;
          }
          handleMobileBlockedNavigation(reason);
        }
      });

      // Always-On Kiosk Lockdown from startup on Android & iOS
      await setMode(AssessmentMode.exam);
    }
  }

  void dispose() {
    _watchdogTimer?.cancel();
    _alertClearTimer?.cancel();
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
    } else if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      try {
        await _mobileChannel.invokeMethod('exitApp');
      } catch (e) {
        debugPrint('[KioskSecurityService] Error during mobile exit cleanup: $e');
      }
      await SystemNavigator.pop();
      return;
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
      } else if (_currentMode == AssessmentMode.exam ||
                 _currentMode == AssessmentMode.strictExam ||
                 _currentMode == AssessmentMode.essayExam) {
        await _setKioskHook(false);
        await _setWindowLock(true);
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        await windowManager.setResizable(false);
        await windowManager.setMinimizable(false);
        await windowManager.setMaximizable(false);
        if (await windowManager.isFullScreen()) {
          await windowManager.setFullScreen(false);
        }
        await windowManager.maximize();
        await windowManager.setAlwaysOnTop(false);
      }
    } else if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      if (devBypassLockdown) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        try {
          await _mobileChannel.invokeMethod('setKioskLockdown', {'enabled': false});
          await _mobileChannel.invokeMethod('setFlagSecure', {'enabled': false});
        } catch (e) {
          debugPrint('[KioskSecurityService] Failed to disable mobile kiosk lockdown: $e');
        }
      } else {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        try {
          await _mobileChannel.invokeMethod('setKioskLockdown', {'enabled': true});
          await _mobileChannel.invokeMethod('setFlagSecure', {'enabled': true});
        } catch (e) {
          debugPrint('[KioskSecurityService] Failed to enable mobile kiosk lockdown: $e');
        }
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
    // On Android & iOS, Always-On Kiosk remains in AssessmentMode.exam unless
    // explicitly unlocked by a supervisor (isManualOverride) or devBypassLockdown.
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      if (mode == AssessmentMode.normal) {
        if (isOfficeSessionActive) {
          markOfficeSessionEnded();
        }
        if (!isManualOverride && !devBypassLockdown) {
          if (_currentMode == AssessmentMode.normal) {
            mode = AssessmentMode.exam;
          } else {
            return;
          }
        }
      }
    }

    if (_currentMode == mode) return;
    _applyModeState(mode);

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

        case AssessmentMode.exam:
        case AssessmentMode.strictExam:
        case AssessmentMode.essayExam:
          // Unified exam mode:
          // 1. Unhook Alt+Tab to allow switching between ARA, Word, Excel, and PowerPoint
          await _setKioskHook(false);
          // 2. Lock window controls so ARA cannot be closed, minimized, or resized (native WS_SYSMENU stripped)
          await _setWindowLock(true);
          if (!devBypassLockdown) {
            await windowManager.setTitleBarStyle(TitleBarStyle.normal);
            await windowManager.setResizable(false);
            await windowManager.setMinimizable(false);
            await windowManager.setMaximizable(false);
            // Show taskbar: NOT fullscreen, but MAXIMIZED!
            if (await windowManager.isFullScreen()) {
              await windowManager.setFullScreen(false);
            }
            await windowManager.maximize();
            // Don't stay on top so Word, Excel, and PowerPoint can appear over ARA
            await windowManager.setAlwaysOnTop(false);
          }
          await windowManager.setPreventClose(!isDevMode || !devBypassLockdown);
          _startWatchdog();
          break;
      }
    } else if (Platform.isAndroid || Platform.isIOS) {
      switch (mode) {
        case AssessmentMode.normal:
          await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
          try {
            await _mobileChannel.invokeMethod('setKioskLockdown', {'enabled': false});
            await _mobileChannel.invokeMethod('setFlagSecure', {'enabled': false});
          } catch (e) {
            debugPrint('[KioskSecurityService] Failed to unlock mobile kiosk: $e');
          }
          break;

        case AssessmentMode.exam:
        case AssessmentMode.strictExam:
        case AssessmentMode.essayExam:
          // Mobile Kiosk (Android & iOS):
          // 1. Fullscreen sticky immersive mode (hide system status & nav bars)
          await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
          // 2. Enable native kiosk lockdown (Back/Minimize/Recents/Split-Screen/Screen-Capture protection)
          try {
            await _mobileChannel.invokeMethod('setKioskLockdown', {'enabled': !devBypassLockdown});
            await _mobileChannel.invokeMethod('setFlagSecure', {'enabled': !devBypassLockdown});
          } catch (e) {
            debugPrint('[KioskSecurityService] Failed to set mobile kiosk lockdown: $e');
          }
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

    // 2. Unified Exam Mode: Word, Excel, PowerPoint, and system shell permitted; all other apps blocked
    if (mode == AssessmentMode.exam ||
        mode == AssessmentMode.strictExam ||
        mode == AssessmentMode.essayExam) {
      // Handle explorer.exe: Distinguish Taskbar/Desktop vs File Explorer (CabinetWClass) and Run dialog
      if (lowerExe == 'explorer.exe') {
        if (className == 'CabinetWClass' || className == 'ExploreWClass') {
          return const SecurityPolicyEvaluation(
            WindowAction.block,
            'File Explorer diblokir! Anda tidak diizinkan membuka folder/file selama sesi ujian.',
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
        return const SecurityPolicyEvaluation(WindowAction.allow, 'Exam whitelist');
      }

      return SecurityPolicyEvaluation(
        WindowAction.block,
        'Aplikasi "$lowerExe" diblokir! Pada sesi ujian, hanya Microsoft Word, Excel, dan PowerPoint yang diizinkan.',
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
    // Watchdog handles active window verification
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
