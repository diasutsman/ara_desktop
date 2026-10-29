import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'config/env_config.dart';
import 'services/kiosk_security_service.dart';
import 'ui/webview_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Always accept all SSL/TLS certificates globally across Dart HttpClient calls
  HttpOverrides.global = _AraIgnoreSslHttpOverrides();

  // Initialize environment configuration (.env)
  await EnvConfig().initialize();

  // Initialize desktop window manager if running on Desktop (Windows, macOS, Linux)
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(
      size: Size(1366, 768),
      minimumSize: Size(1024, 600),
      center: true,
      backgroundColor: Colors.white,
      skipTaskbar: false,
      title: 'ARA Assessment',
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // Initialize Kiosk & Process Watchdog
  await KioskSecurityService().initialize();

  // Set system UI styling for mobile
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.black,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const AraAssessmentApp());
}

class AraAssessmentApp extends StatelessWidget {
  const AraAssessmentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ARA Mobile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF00AEF0),
          surface: Colors.white,
        ),
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white24, width: 1),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          textStyle: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
          waitDuration: const Duration(milliseconds: 300),
        ),
        useMaterial3: true,
      ),
      home: const WebViewScreen(),
    );
  }
}

class _AraIgnoreSslHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  }
}
