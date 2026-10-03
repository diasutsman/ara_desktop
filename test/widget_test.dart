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

    test('evaluateUrl recognizes exam routes', () {
      detector.evaluateUrl('https://ara-assessment.com/ujian/mulai');
      expect(kiosk.currentMode, AssessmentMode.strictExam);

      detector.evaluateUrl('https://ara-assessment.com/exam/question/1');
      expect(kiosk.currentMode, AssessmentMode.strictExam);

      detector.evaluateUrl('https://ara-assessment.com/assessment/live');
      expect(kiosk.currentMode, AssessmentMode.strictExam);
    });

    test('evaluateUrl recognizes essay routes', () {
      detector.evaluateUrl('https://ara-assessment.com/ujian/essay/soal-1');
      expect(kiosk.currentMode, AssessmentMode.essayExam);

      detector.evaluateUrl('https://ara-assessment.com/esai/detail');
      expect(kiosk.currentMode, AssessmentMode.essayExam);
    });

    test('evaluateUrl recognizes normal/exit routes', () {
      detector.evaluateUrl('https://ara-assessment.com/ujian/mulai');
      expect(kiosk.currentMode, AssessmentMode.strictExam);

      detector.evaluateUrl('https://ara-assessment.com/selesai');
      expect(kiosk.currentMode, AssessmentMode.normal);

      detector.evaluateUrl('https://ara-assessment.com/dashboard');
      expect(kiosk.currentMode, AssessmentMode.normal);

      detector.evaluateUrl('https://ara-assessment.com/login');
      expect(kiosk.currentMode, AssessmentMode.normal);
    });

    test('handleModeChange processes string triggers', () {
      detector.handleModeChange('strict');
      expect(kiosk.currentMode, AssessmentMode.strictExam);

      detector.handleModeChange('essay');
      expect(kiosk.currentMode, AssessmentMode.essayExam);

      detector.handleModeChange('normal');
      expect(kiosk.currentMode, AssessmentMode.normal);
    });
  });
}
