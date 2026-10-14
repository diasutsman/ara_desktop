import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

class OfficeLaunchResult {
  final bool success;
  final String message;
  final bool openedStore;

  const OfficeLaunchResult({
    required this.success,
    required this.message,
    this.openedStore = false,
  });
}

/// Per-application launch configuration for Microsoft Office apps across platforms.
/// Shared by [OfficeLauncherService] (launch app) and OfficeDocumentService (open document).
class OfficeAppConfig {
  final String name;
  final String windowsCommand;
  final String macAppName;
  final String linuxCommand;

  /// Android packages in priority order (dedicated app first, Microsoft 365 hub as fallback).
  final List<String> androidPackages;

  /// URI schemes in priority order. `ms-word://` is tried before `ms-word:` because some
  /// iOS/Android Office builds only respond to the authority form.
  final List<String> schemes;
  final String androidStoreUrl;
  final String iosStoreUrl;

  const OfficeAppConfig({
    required this.name,
    required this.windowsCommand,
    required this.macAppName,
    required this.linuxCommand,
    required this.androidPackages,
    required this.schemes,
    required this.androidStoreUrl,
    required this.iosStoreUrl,
  });

  static const OfficeAppConfig word = OfficeAppConfig(
    name: 'Microsoft Word',
    windowsCommand: 'winword',
    macAppName: 'Microsoft Word',
    linuxCommand: 'libreoffice --writer',
    androidPackages: [
      'com.microsoft.office.word',
      'com.microsoft.office.officehubrow',
    ],
    schemes: ['ms-word://', 'ms-word:', 'ms-office:'],
    androidStoreUrl: 'https://play.google.com/store/apps/details?id=com.microsoft.office.word',
    iosStoreUrl: 'https://apps.apple.com/app/microsoft-word/id586447913',
  );

  static const OfficeAppConfig excel = OfficeAppConfig(
    name: 'Microsoft Excel',
    windowsCommand: 'excel',
    macAppName: 'Microsoft Excel',
    linuxCommand: 'libreoffice --calc',
    androidPackages: [
      'com.microsoft.office.excel',
      'com.microsoft.office.officehubrow',
    ],
    schemes: ['ms-excel://', 'ms-excel:', 'ms-office:'],
    androidStoreUrl: 'https://play.google.com/store/apps/details?id=com.microsoft.office.excel',
    iosStoreUrl: 'https://apps.apple.com/app/microsoft-excel/id586683407',
  );

  static const OfficeAppConfig powerPoint = OfficeAppConfig(
    name: 'Microsoft PowerPoint',
    windowsCommand: 'powerpnt',
    macAppName: 'Microsoft PowerPoint',
    linuxCommand: 'libreoffice --impress',
    androidPackages: [
      'com.microsoft.office.powerpoint',
      'com.microsoft.office.officehubrow',
    ],
    schemes: ['ms-powerpoint://', 'ms-powerpoint:', 'ms-office:'],
    androidStoreUrl: 'https://play.google.com/store/apps/details?id=com.microsoft.office.powerpoint',
    iosStoreUrl: 'https://apps.apple.com/app/microsoft-powerpoint/id586449534',
  );
}

class OfficeLauncherService {
  static final OfficeLauncherService _instance = OfficeLauncherService._internal();
  factory OfficeLauncherService() => _instance;
  OfficeLauncherService._internal();

  static const MethodChannel _mobileChannel = MethodChannel('ara_desktop/mobile_kiosk');

  /// Launch Microsoft Word
  Future<OfficeLaunchResult> launchWord() => _launchApp(OfficeAppConfig.word);

  /// Launch Microsoft Excel
  Future<OfficeLaunchResult> launchExcel() => _launchApp(OfficeAppConfig.excel);

  /// Launch Microsoft PowerPoint
  Future<OfficeLaunchResult> launchPowerPoint() => _launchApp(OfficeAppConfig.powerPoint);

  /// Opens the Google Play Store / Apple App Store page for [app] so the user can install it.
  Future<OfficeLaunchResult> openStoreFor(OfficeAppConfig app) async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      return OfficeLaunchResult(
        success: false,
        message: '${app.name} belum terinstal pada perangkat ini.',
      );
    }
    final isAndroid = Platform.isAndroid;
    final storeUri = Uri.parse(isAndroid ? app.androidStoreUrl : app.iosStoreUrl);
    try {
      await launchUrl(storeUri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[OfficeLauncher] Failed to open store for ${app.name}: $e');
    }
    return OfficeLaunchResult(
      success: false,
      openedStore: true,
      message: '${app.name} belum terinstal. Membuka ${isAndroid ? 'Google Play Store' : 'App Store'} untuk mengunduh...',
    );
  }

  /// Tries the app's URI schemes in order. Returns true when one of them launched.
  Future<bool> _tryLaunchSchemes(List<String> schemes) async {
    for (final scheme in schemes) {
      try {
        final uri = Uri.parse(scheme);
        if (await canLaunchUrl(uri)) {
          final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
          if (launched) {
            debugPrint('[OfficeLauncher] Launched via scheme: $scheme');
            return true;
          }
        }
      } catch (e) {
        debugPrint('[OfficeLauncher] Scheme $scheme failed: $e');
      }
    }
    return false;
  }

  Future<OfficeLaunchResult> _launchApp(OfficeAppConfig app) async {
    final name = app.name;
    if (kIsWeb) {
      return const OfficeLaunchResult(
        success: false,
        message: 'Peluncuran aplikasi lokal tidak didukung di web browser.',
      );
    }

    try {
      if (Platform.isWindows) {
        // Use cmd /c start "" command to allow Windows App Paths resolution for MS Office
        final result = await Process.run('cmd', ['/c', 'start', '', app.windowsCommand]);
        if (result.exitCode == 0) {
          debugPrint('[OfficeLauncher] Successfully launched $name (${app.windowsCommand})');
          return OfficeLaunchResult(
            success: true,
            message: 'Berhasil membuka $name.',
          );
        } else {
          final errStr = result.stderr.toString().trim();
          debugPrint('[OfficeLauncher] Failed to launch $name: $errStr');
          return OfficeLaunchResult(
            success: false,
            message: 'Gagal membuka $name. Pastikan Microsoft Office telah terinstal pada komputer ini.',
          );
        }
      } else if (Platform.isAndroid) {
        // 1. Try launching through native package manager via MethodChannel
        for (final pkg in app.androidPackages) {
          try {
            final launched = await _mobileChannel.invokeMethod<bool>('launchPackage', {'package': pkg});
            if (launched == true) {
              debugPrint('[OfficeLauncher] Successfully launched Android package: $pkg');
              return OfficeLaunchResult(
                success: true,
                message: 'Berhasil membuka $name.',
              );
            }
          } catch (e) {
            debugPrint('[OfficeLauncher] MethodChannel launchPackage error for $pkg: $e');
          }
        }

        // 2. Try URI schemes via url_launcher
        if (await _tryLaunchSchemes(app.schemes)) {
          return OfficeLaunchResult(success: true, message: 'Berhasil membuka $name.');
        }

        // 3. Fallback: Open Google Play Store page so user can install the app
        return await openStoreFor(app);
      } else if (Platform.isIOS) {
        // 1. Try URI schemes via url_launcher (requires LSApplicationQueriesSchemes in Info.plist)
        if (await _tryLaunchSchemes(app.schemes)) {
          return OfficeLaunchResult(success: true, message: 'Berhasil membuka $name.');
        }

        // 2. Fallback: Open App Store link
        return await openStoreFor(app);
      } else if (Platform.isMacOS) {
        final result = await Process.run('open', ['-a', app.macAppName]);
        if (result.exitCode == 0) {
          return OfficeLaunchResult(success: true, message: 'Berhasil membuka $name.');
        } else {
          return OfficeLaunchResult(
            success: false,
            message: 'Gagal membuka $name di macOS. Pastikan aplikasi telah terinstal.',
          );
        }
      } else if (Platform.isLinux) {
        final parts = app.linuxCommand.split(' ');
        await Process.start(parts[0], parts.sublist(1), mode: ProcessStartMode.detached);
        return OfficeLaunchResult(success: true, message: 'Berhasil membuka $name.');
      }

      return const OfficeLaunchResult(
        success: false,
        message: 'Platform ini tidak mendukung peluncuran aplikasi lokal.',
      );
    } catch (e) {
      debugPrint('[OfficeLauncher] Exception while launching $name: $e');
      return OfficeLaunchResult(
        success: false,
        message: 'Terjadi kesalahan saat meluncurkan $name: $e',
      );
    }
  }
}
