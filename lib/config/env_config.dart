import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

enum AppTargetMode {
  local,
  production,
}

class EnvConfig {
  static final EnvConfig _instance = EnvConfig._internal();
  factory EnvConfig() => _instance;
  EnvConfig._internal();

  static const String defaultProductionUrl = 'https://ara-assessment.com/assess/login';
  static const String defaultLocalDesktopUrl = 'http://localhost/new_ara';
  static const String defaultLocalMobileUrl = 'http://192.168.100.7/new_ara';

  /// ValueNotifier for current server target mode (Local vs Production)
  final ValueNotifier<AppTargetMode> targetModeNotifier =
      ValueNotifier<AppTargetMode>(AppTargetMode.production);

  /// ValueNotifier for whether dev mode is enabled
  final ValueNotifier<bool> devModeNotifier = ValueNotifier<bool>(kDebugMode);

  /// ValueNotifier for whether window lockdown bypass is active
  final ValueNotifier<bool> bypassLockdownNotifier = ValueNotifier<bool>(false);

  AppTargetMode get targetMode => targetModeNotifier.value;
  set targetMode(AppTargetMode mode) {
    targetModeNotifier.value = mode;
  }

  bool get isDevMode => devModeNotifier.value;
  set isDevMode(bool val) {
    devModeNotifier.value = val;
  }

  bool get devBypassLockdown => bypassLockdownNotifier.value;
  set devBypassLockdown(bool val) {
    bypassLockdownNotifier.value = val;
  }

  bool recordViolationsInDev = true;

  String productionUrl = defaultProductionUrl;
  String localDesktopUrl = defaultLocalDesktopUrl;
  String localMobileUrl = defaultLocalMobileUrl;
  String? customLocalUrl;

  /// Loads configuration from .env file with safe fallbacks
  Future<void> initialize() async {
    try {
      await dotenv.load(fileName: ".env");
      debugPrint('[EnvConfig] Successfully loaded .env configuration');
    } catch (e) {
      debugPrint('[EnvConfig] Warning: .env file could not be loaded ($e). Using safe defaults.');
    }

    // 1. Resolve Target Mode: 'local' vs 'production'
    final modeStr = (dotenv.maybeGet('APP_MODE') ?? 'local').toLowerCase().trim();
    if (modeStr == 'local' || modeStr == 'localhost' || modeStr == 'dev') {
      targetModeNotifier.value = AppTargetMode.local;
    } else {
      targetModeNotifier.value = AppTargetMode.production;
    }

    // 2. Resolve Dev Mode
    final devModeStr = dotenv.maybeGet('DEV_MODE');
    if (devModeStr != null) {
      devModeNotifier.value = devModeStr.toLowerCase().trim() == 'true' || devModeStr.trim() == '1';
    } else {
      // Default to true in debug mode or if APP_ENV=development
      final appEnv = dotenv.maybeGet('APP_ENV')?.toLowerCase().trim();
      devModeNotifier.value = appEnv == 'development' || kDebugMode;
    }

    // 3. Resolve Dev Bypass Lockdown (default false to keep proctoring watchdog active)
    final bypassStr = dotenv.maybeGet('DEV_BYPASS_LOCKDOWN');
    if (bypassStr != null) {
      bypassLockdownNotifier.value = bypassStr.toLowerCase().trim() == 'true' || bypassStr.trim() == '1';
    } else {
      bypassLockdownNotifier.value = false;
    }

    // 4. Resolve Dev Violations Recording (default true)
    final recordViolationsStr = dotenv.maybeGet('DEV_RECORD_VIOLATIONS');
    if (recordViolationsStr != null) {
      recordViolationsInDev = recordViolationsStr.toLowerCase().trim() == 'true' || recordViolationsStr.trim() == '1';
    } else {
      recordViolationsInDev = true;
    }

    // 5. Target URLs
    productionUrl = dotenv.maybeGet('PRODUCTION_URL')?.trim() ?? defaultProductionUrl;
    localDesktopUrl = dotenv.maybeGet('LOCAL_URL_DESKTOP')?.trim() ?? defaultLocalDesktopUrl;
    localMobileUrl = dotenv.maybeGet('LOCAL_URL_MOBILE')?.trim() ?? defaultLocalMobileUrl;
    customLocalUrl = dotenv.maybeGet('LOCAL_URL')?.trim();

    debugPrint('[EnvConfig] Initialized -> Mode: ${targetMode.name.toUpperCase()}, DevMode: $isDevMode, BypassLockdown: $devBypassLockdown, Current URL: $currentUrl');
  }

  /// Returns the appropriate local URL depending on platform
  String get localUrl {
    if (customLocalUrl != null && customLocalUrl!.isNotEmpty) {
      return customLocalUrl!;
    }
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      return localMobileUrl;
    }
    return localDesktopUrl;
  }

  /// Returns the current active base URL
  String get currentUrl {
    switch (targetMode) {
      case AppTargetMode.local:
        return localUrl;
      case AppTargetMode.production:
        return productionUrl;
    }
  }

  bool get isLocal => targetMode == AppTargetMode.local;
  bool get isProduction => targetMode == AppTargetMode.production;

  /// Switch mode between local and production
  void toggleMode() {
    if (targetMode == AppTargetMode.local) {
      targetMode = AppTargetMode.production;
    } else {
      targetMode = AppTargetMode.local;
    }
  }
}
