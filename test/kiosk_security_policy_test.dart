import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:ara_desktop/services/kiosk_security_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Kiosk Security Policy & Exploit Patch Tests', () {
    late KioskSecurityService service;

    setUp(() {
      service = KioskSecurityService();
      service.isDevMode = true;
      service.devBypassLockdown = false;
    });

    // -------------------------------------------------------------
    // EXPLOIT 1 & 6: Elevated Processes with Empty Exe Name (Device Manager, Regedit, Task Manager)
    // -------------------------------------------------------------
    group('Exploit 1 & 6: Elevated Process & Empty Executable Name', () {
      test('Device Manager (MMCMainFrame) with empty process name MUST be blocked in Strict Mode', () {
        final eval = service.evaluateWindowPolicy(
          mode: AssessmentMode.strictExam,
          processExe: '',
          className: 'MMCMainFrame',
          windowTitle: 'Device Manager',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(eval.isBlocked, isTrue);
        expect(eval.reason, contains('Aplikasi sistem atau elevated'));
      });

      test('Device Manager (MMCMainFrame) with empty process name MUST be blocked in Essay Mode', () {
        final eval = service.evaluateWindowPolicy(
          mode: AssessmentMode.essayExam,
          processExe: '',
          className: 'MMCMainFrame',
          windowTitle: 'Device Manager',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(eval.isBlocked, isTrue);
        expect(eval.reason, contains('Aplikasi sistem atau elevated'));
      });

      test('Registry Editor (RegEdit_RegEdit) with empty process name MUST be blocked', () {
        final eval = service.evaluateWindowPolicy(
          mode: AssessmentMode.essayExam,
          processExe: '',
          className: 'RegEdit_RegEdit',
          windowTitle: 'Registry Editor',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(eval.isBlocked, isTrue);
      });

      test('Taskbar (Shell_TrayWnd) with empty process name is ALLOWED so student can see taskbar', () {
        final eval = service.evaluateWindowPolicy(
          mode: AssessmentMode.essayExam,
          processExe: '',
          className: 'Shell_TrayWnd',
          windowTitle: '',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(eval.isAllowed, isTrue);
      });

      test('Desktop (Progman / WorkerW) with empty process name is ALLOWED', () {
        final eval = service.evaluateWindowPolicy(
          mode: AssessmentMode.essayExam,
          processExe: '',
          className: 'WorkerW',
          windowTitle: '',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(eval.isAllowed, isTrue);
      });
    });

    // -------------------------------------------------------------
    // EXPLOIT 2: Essay Mode Whitelist (Word, PPT) vs Blacklist (Excel, Chrome, Edge)
    // -------------------------------------------------------------
    group('Exploit 2: Essay / Utilities Whitelist (Word, PPT, Excel) vs Blacklist (Chrome, Edge)', () {
      test('Microsoft Word (winword.exe) is ALLOWED in Essay Mode', () {
        final eval = service.evaluateWindowPolicy(
          mode: AssessmentMode.essayExam,
          processExe: 'winword.exe',
          className: 'OpusApp',
          windowTitle: 'Document1 - Microsoft Word',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(eval.isAllowed, isTrue);
      });

      test('Microsoft PowerPoint (powerpnt.exe) is ALLOWED in Essay Mode', () {
        final eval = service.evaluateWindowPolicy(
          mode: AssessmentMode.essayExam,
          processExe: 'powerpnt.exe',
          className: 'PPTFrameClass',
          windowTitle: 'Presentation1 - Microsoft PowerPoint',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(eval.isAllowed, isTrue);
      });

      test('Microsoft Excel (excel.exe) is ALLOWED in Essay Mode', () {
        final eval = service.evaluateWindowPolicy(
          mode: AssessmentMode.essayExam,
          processExe: 'excel.exe',
          className: 'XLMAIN',
          windowTitle: 'Book1 - Microsoft Excel',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(eval.isAllowed, isTrue);
      });

      test('Google Chrome (chrome.exe) MUST BE BLOCKED in Essay Mode', () {
        final eval = service.evaluateWindowPolicy(
          mode: AssessmentMode.essayExam,
          processExe: 'chrome.exe',
          className: 'Chrome_WidgetWin_1',
          windowTitle: 'Google - Google Chrome',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(eval.isBlocked, isTrue);
      });

      test('Microsoft Edge (msedge.exe) MUST BE BLOCKED in Essay Mode', () {
        final eval = service.evaluateWindowPolicy(
          mode: AssessmentMode.essayExam,
          processExe: 'msedge.exe',
          className: 'Chrome_WidgetWin_1',
          windowTitle: 'New Tab - Microsoft Edge',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(eval.isBlocked, isTrue);
      });
    });

    // -------------------------------------------------------------
    // EXPLOIT 3: UWP Windows Settings & Calculator Container
    // -------------------------------------------------------------
    group('Exploit 3: UWP Windows Settings (ApplicationFrameHost)', () {
      test('Windows Settings / UWP container (ApplicationFrameHost.exe) MUST BE BLOCKED', () {
        final eval = service.evaluateWindowPolicy(
          mode: AssessmentMode.essayExam,
          processExe: 'applicationframehost.exe',
          className: 'ApplicationFrameWindow',
          windowTitle: 'Settings',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(eval.isBlocked, isTrue);
      });

      test('SystemSettings.exe MUST BE BLOCKED in Essay Mode', () {
        final eval = service.evaluateWindowPolicy(
          mode: AssessmentMode.essayExam,
          processExe: 'systemsettings.exe',
          className: 'Windows.UI.Core.CoreWindow',
          windowTitle: 'Settings',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(eval.isBlocked, isTrue);
      });
    });

    // -------------------------------------------------------------
    // EXPLOIT 4 & 5: File Explorer & Run Dialog under explorer.exe
    // -------------------------------------------------------------
    group('Exploit 4 & 5: File Explorer & Run Dialog under explorer.exe', () {
      test('Taskbar (Shell_TrayWnd) under explorer.exe is ALLOWED', () {
        final eval = service.evaluateWindowPolicy(
          mode: AssessmentMode.essayExam,
          processExe: 'explorer.exe',
          className: 'Shell_TrayWnd',
          windowTitle: '',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(eval.isAllowed, isTrue);
      });

      test('File Explorer folder (CabinetWClass) under explorer.exe MUST BE BLOCKED', () {
        final eval = service.evaluateWindowPolicy(
          mode: AssessmentMode.essayExam,
          processExe: 'explorer.exe',
          className: 'CabinetWClass',
          windowTitle: 'This PC',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(eval.isBlocked, isTrue);
        expect(eval.reason, contains('File Explorer diblokir'));
      });

      test('File Explorer legacy folder (ExploreWClass) under explorer.exe MUST BE BLOCKED', () {
        final eval = service.evaluateWindowPolicy(
          mode: AssessmentMode.essayExam,
          processExe: 'explorer.exe',
          className: 'ExploreWClass',
          windowTitle: 'Documents',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(eval.isBlocked, isTrue);
        expect(eval.reason, contains('File Explorer diblokir'));
      });

      test('Run dialog (#32770) under explorer.exe MUST BE BLOCKED', () {
        final eval = service.evaluateWindowPolicy(
          mode: AssessmentMode.essayExam,
          processExe: 'explorer.exe',
          className: '#32770',
          windowTitle: 'Run',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(eval.isBlocked, isTrue);
        expect(eval.reason, contains('Kotak dialog Run diblokir'));
      });
    });

    // -------------------------------------------------------------
    // STRICT EXAM MODE & GENERAL BEHAVIOR
    // -------------------------------------------------------------
    group('Strict Exam Mode & Own Process', () {
      test('Own Process is always ALLOWED in any mode', () {
        final eval = service.evaluateWindowPolicy(
          mode: AssessmentMode.strictExam,
          processExe: 'ara_desktop.exe',
          className: 'FLUTTER_RUNNER_WIN32_WINDOW',
          windowTitle: 'ARA Assessment',
          isOwnProcess: true,
          isDevBypass: false,
        );
        expect(eval.isAllowed, isTrue);
      });

      test('Unified Exam Mode ALLOWS Word, Excel, and PowerPoint', () {
        final evalWord = service.evaluateWindowPolicy(
          mode: AssessmentMode.exam,
          processExe: 'winword.exe',
          className: 'OpusApp',
          windowTitle: 'Document1',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(evalWord.isAllowed, isTrue);

        final evalExcel = service.evaluateWindowPolicy(
          mode: AssessmentMode.exam,
          processExe: 'excel.exe',
          className: 'XLMAIN',
          windowTitle: 'Book1',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(evalExcel.isAllowed, isTrue);

        final evalPpt = service.evaluateWindowPolicy(
          mode: AssessmentMode.exam,
          processExe: 'powerpnt.exe',
          className: 'PPTFrameClass',
          windowTitle: 'Presentation1',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(evalPpt.isAllowed, isTrue);
      });

      test('Unified Exam Mode BLOCKS unauthorized apps like Chrome', () {
        final evalChrome = service.evaluateWindowPolicy(
          mode: AssessmentMode.exam,
          processExe: 'chrome.exe',
          className: 'Chrome_WidgetWin_1',
          windowTitle: 'Google Chrome',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(evalChrome.isBlocked, isTrue);
      });

      test('Normal Mode ALLOWS all applications', () {
        final eval = service.evaluateWindowPolicy(
          mode: AssessmentMode.normal,
          processExe: 'excel.exe',
          className: 'XLMAIN',
          windowTitle: 'Book1',
          isOwnProcess: false,
          isDevBypass: false,
        );
        expect(eval.isAllowed, isTrue);
      });
    });

    // -------------------------------------------------------------
    // MOBILE KIOSK & OFFICE SESSION TESTS
    // -------------------------------------------------------------
    group('Mobile Kiosk Lifecycle & Office Session', () {
      test('Leaving app during exam without Office session records a security violation', () {
        service.currentMode = AssessmentMode.exam;
        service.violationCount = 0;
        service.securityAlertNotifier.value = null;
        service.isOfficeSessionActive = false;

        service.handleAppLifecycleChange(AppLifecycleState.paused);

        expect(service.violationCount, equals(1));
        expect(service.securityAlertNotifier.value, contains('PERINGATAN: Anda terdeteksi meninggalkan aplikasi ARA Assessment'));
      });

      test('Leaving app during exam with an active Office session is PERMITTED (no violation)', () {
        service.currentMode = AssessmentMode.exam;
        service.violationCount = 0;
        service.securityAlertNotifier.value = null;

        service.markOfficeSessionStarted();
        expect(service.isOfficeSessionActive, isTrue);

        service.handleAppLifecycleChange(AppLifecycleState.paused);

        expect(service.violationCount, equals(0));
        expect(service.securityAlertNotifier.value, isNull);

        // Returning to the app keeps the Office session for the rest of the exam
        service.handleAppLifecycleChange(AppLifecycleState.resumed);
        expect(service.isOfficeSessionActive, isTrue);
      });

      test('Switching back and forth between ARA and Office multiple times records no violation', () {
        service.currentMode = AssessmentMode.exam;
        service.violationCount = 0;
        service.securityAlertNotifier.value = null;
        service.markOfficeSessionStarted();

        for (var i = 0; i < 3; i++) {
          service.handleAppLifecycleChange(AppLifecycleState.paused);
          service.handleAppLifecycleChange(AppLifecycleState.resumed);
        }

        expect(service.violationCount, equals(0));
        expect(service.securityAlertNotifier.value, isNull);
        expect(service.isOfficeSessionActive, isTrue);
      });

      test('Returning to Normal mode ends the Office session', () {
        service.currentMode = AssessmentMode.exam;
        service.markOfficeSessionStarted();
        expect(service.isOfficeSessionActive, isTrue);

        service.currentMode = AssessmentMode.normal;
        expect(service.isOfficeSessionActive, isFalse);

        // A new exam without opening Office again is strict again
        service.currentMode = AssessmentMode.exam;
        service.violationCount = 0;
        service.handleAppLifecycleChange(AppLifecycleState.paused);
        expect(service.violationCount, equals(1));
      });

      test('Leaving app in Normal mode records no violation', () {
        service.currentMode = AssessmentMode.normal;
        service.violationCount = 0;
        service.securityAlertNotifier.value = null;

        service.handleAppLifecycleChange(AppLifecycleState.paused);

        expect(service.violationCount, equals(0));
        expect(service.securityAlertNotifier.value, isNull);
      });
    });
  });
}
