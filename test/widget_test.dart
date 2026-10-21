import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ara_desktop/services/assessment_detector.dart';
import 'package:ara_desktop/services/kiosk_security_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Mock window_manager channel calls for unit testing
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (MethodCall methodCall) async {
      return true;
    },
  );

  group('KioskSecurityService Tests', () {
    test('Initial mode should be normal', () {
      final service = KioskSecurityService();
      expect(service.currentMode, AssessmentMode.normal);
      expect(service.modeNotifier.value, AssessmentMode.normal);
    });

    test('Setting mode updates currentMode and notifier', () async {
      final service = KioskSecurityService();
      await service.setMode(AssessmentMode.strictExam);
      expect(service.currentMode, AssessmentMode.strictExam);
      expect(service.modeNotifier.value, AssessmentMode.strictExam);

      await service.setMode(AssessmentMode.essayExam);
      expect(service.currentMode, AssessmentMode.essayExam);
      expect(service.modeNotifier.value, AssessmentMode.essayExam);

      await service.setMode(AssessmentMode.normal);
      expect(service.currentMode, AssessmentMode.normal);
      expect(service.modeNotifier.value, AssessmentMode.normal);
    });

    test('Dev mode and lockdown bypass flags operate correctly', () async {
      final service = KioskSecurityService();
      expect(service.isDevMode, true); // True by default in debug/test mode
      expect(service.devBypassLockdown, false);

      await service.toggleDevBypassLockdown();
      expect(service.devBypassLockdown, true);

      await service.toggleDevBypassLockdown();
      expect(service.devBypassLockdown, false);
    });
  });

  group('AssessmentDetector Tests', () {
    late AssessmentDetector detector;
    late KioskSecurityService kiosk;

    setUp(() {
      detector = AssessmentDetector();
      kiosk = KioskSecurityService();
    });

    tearDown(() async {
      await kiosk.setMode(AssessmentMode.normal);
    });

    test('evaluateUrl recognizes exam routes as unified exam', () {
      detector.evaluateUrl('https://ara-assessment.com/ujian/mulai');
      expect(kiosk.currentMode, AssessmentMode.exam);

      detector.evaluateUrl('https://ara-assessment.com/exam/question/1');
      expect(kiosk.currentMode, AssessmentMode.exam);

      detector.evaluateUrl('https://ara-assessment.com/soal/1');
      expect(kiosk.currentMode, AssessmentMode.exam);
    });

    test('evaluateUrl recognizes base assess landing and login as normal', () {
      detector.evaluateUrl('https://ara-assessment.com/assess');
      expect(kiosk.currentMode, AssessmentMode.normal);

      detector.evaluateUrl('https://ara-assessment.com/assess/');
      expect(kiosk.currentMode, AssessmentMode.normal);

      detector.evaluateUrl('https://ara-assessment.com/assess/login');
      expect(kiosk.currentMode, AssessmentMode.normal);
    });

    test('evaluateUrl recognizes essay routes as unified exam', () {
      detector.evaluateUrl('https://ara-assessment.com/ujian/essay/soal-1');
      expect(kiosk.currentMode, AssessmentMode.exam);

      detector.evaluateUrl('https://ara-assessment.com/esai/detail');
      expect(kiosk.currentMode, AssessmentMode.exam);
    });

    test('evaluateUrl recognizes normal/exit routes', () {
      detector.evaluateUrl('https://ara-assessment.com/ujian/mulai');
      expect(kiosk.currentMode, AssessmentMode.exam);

      detector.evaluateUrl('https://ara-assessment.com/selesai');
      expect(kiosk.currentMode, AssessmentMode.normal);

      detector.evaluateUrl('https://ara-assessment.com/dashboard');
      expect(kiosk.currentMode, AssessmentMode.normal);

      detector.evaluateUrl('https://ara-assessment.com/login');
      expect(kiosk.currentMode, AssessmentMode.normal);
    });

    test('evaluateUrl recognizes profile, user, verification, and onboarding routes as normal', () {
      detector.evaluateUrl('https://ara-assessment.com/user/profile');
      expect(kiosk.currentMode, AssessmentMode.normal);

      detector.evaluateUrl('https://ara-assessment.com/profile');
      expect(kiosk.currentMode, AssessmentMode.normal);

      detector.evaluateUrl('https://ara-assessment.com/verifikasi');
      expect(kiosk.currentMode, AssessmentMode.normal);

      detector.evaluateUrl('https://ara-assessment.com/user/password');
      expect(kiosk.currentMode, AssessmentMode.normal);

      detector.evaluateUrl('https://ara-assessment.com/user/log');
      expect(kiosk.currentMode, AssessmentMode.normal);
    });

    test('evaluateUrl automatically reverts exam mode to normal when navigating to non-exam route', () {
      detector.evaluateUrl('https://ara-assessment.com/ujian/mulai');
      expect(kiosk.currentMode, AssessmentMode.exam);

      // Navigating to profile or user dashboard reverts mode to normal
      detector.evaluateUrl('https://ara-assessment.com/user/profile');
      expect(kiosk.currentMode, AssessmentMode.normal);
    });

    test('handleModeChange processes string triggers', () {
      detector.handleModeChange('strict');
      expect(kiosk.currentMode, AssessmentMode.exam);

      detector.handleModeChange('essay');
      expect(kiosk.currentMode, AssessmentMode.exam);

      detector.handleModeChange('exam');
      expect(kiosk.currentMode, AssessmentMode.exam);

      detector.handleModeChange('normal');
      expect(kiosk.currentMode, AssessmentMode.normal);
    });
  });
}
