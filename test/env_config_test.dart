import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ara_desktop/config/env_config.dart';
import 'package:ara_desktop/services/kiosk_security_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EnvConfig Tests', () {
    late EnvConfig envConfig;

    setUp(() {
      envConfig = EnvConfig();
    });

    test('EnvConfig defaults and URL resolution operate correctly', () {
      expect(envConfig.productionUrl, contains('https://ara-assessment.com'));
      expect(envConfig.localDesktopUrl, contains('localhost'));

      // Test local mode
      envConfig.targetMode = AppTargetMode.local;
      expect(envConfig.isLocal, isTrue);
      expect(envConfig.isProduction, isFalse);
      expect(envConfig.currentUrl, equals(envConfig.localUrl));

      // Test production mode
      envConfig.targetMode = AppTargetMode.production;
      expect(envConfig.isProduction, isTrue);
      expect(envConfig.isLocal, isFalse);
      expect(envConfig.currentUrl, equals(envConfig.productionUrl));

      // Test toggleMode
      envConfig.toggleMode();
      expect(envConfig.isLocal, isTrue);
      envConfig.toggleMode();
      expect(envConfig.isProduction, isTrue);
    });

    test('EnvConfig dev mode and lockdown bypass flags update reactively', () {
      envConfig.isDevMode = true;
      expect(envConfig.isDevMode, isTrue);
      expect(envConfig.devModeNotifier.value, isTrue);

      envConfig.devBypassLockdown = true;
      expect(envConfig.devBypassLockdown, isTrue);
      expect(envConfig.bypassLockdownNotifier.value, isTrue);

      envConfig.devBypassLockdown = false;
      expect(envConfig.devBypassLockdown, isFalse);
      expect(envConfig.bypassLockdownNotifier.value, isFalse);
    });

    test('KioskSecurityService allows dev whitelist apps when in dev mode', () {
      final service = KioskSecurityService();
      service.isDevMode = true;
      service.devBypassLockdown = true;

      // When devBypassLockdown is active in dev mode, apps are allowed bypass
      final eval = service.evaluateWindowPolicy(
        mode: AssessmentMode.exam,
        processExe: 'code.exe',
        className: 'Chrome_WidgetWin_1',
        windowTitle: 'Visual Studio Code',
        isOwnProcess: false,
        isDevBypass: true,
      );
      expect(eval.isAllowed, isTrue);
      expect(eval.reason, contains('Dev mode bypass active'));
    });
  });
}
