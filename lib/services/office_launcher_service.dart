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

class OfficeLauncherService {
  static final OfficeLauncherService _instance = OfficeLauncherService._internal();
  factory OfficeLauncherService() => _instance;
  OfficeLauncherService._internal();

  static const MethodChannel _mobileChannel = MethodChannel('ara_desktop/mobile_kiosk');

  /// Launch Microsoft Word
  Future<OfficeLaunchResult> launchWord() async {
    return _launchApp(
      name: 'Microsoft Word',
      windowsCommand: 'winword',
      macAppName: 'Microsoft Word',
      linuxCommand: 'libreoffice --writer',
      androidPackages: const [
        'com.microsoft.office.word',
        'com.microsoft.office.officehubrow',
      ],
      schemes: const ['ms-word:', 'ms-office:'],
      androidStoreUrl: 'https://play.google.com/store/apps/details?id=com.microsoft.office.word',
      iosStoreUrl: 'https://apps.apple.com/app/microsoft-word/id586447913',
    );
  }

  /// Launch Microsoft Excel
  Future<OfficeLaunchResult> launchExcel() async {
    return _launchApp(
      name: 'Microsoft Excel',
      windowsCommand: 'excel',
      macAppName: 'Microsoft Excel',
      linuxCommand: 'libreoffice --calc',
      androidPackages: const [
        'com.microsoft.office.excel',
        'com.microsoft.office.officehubrow',
      ],
      schemes: const ['ms-excel:', 'ms-office:'],
      androidStoreUrl: 'https://play.google.com/store/apps/details?id=com.microsoft.office.excel',
      iosStoreUrl: 'https://apps.apple.com/app/microsoft-excel/id586683407',
    );
  }

  /// Launch Microsoft PowerPoint
  Future<OfficeLaunchResult> launchPowerPoint() async {
    return _launchApp(
      name: 'Microsoft PowerPoint',
      windowsCommand: 'powerpnt',
      macAppName: 'Microsoft PowerPoint',
      linuxCommand: 'libreoffice --impress',
      androidPackages: const [
        'com.microsoft.office.powerpoint',
        'com.microsoft.office.officehubrow',
      ],
      schemes: const ['ms-powerpoint:', 'ms-office:'],
      androidStoreUrl: 'https://play.google.com/store/apps/details?id=com.microsoft.office.powerpoint',
      iosStoreUrl: 'https://apps.apple.com/app/microsoft-powerpoint/id586449534',
    );
  }

  Future<OfficeLaunchResult> _launchApp({
    required String name,
    required String windowsCommand,
    required String macAppName,
    required String linuxCommand,
    required List<String> androidPackages,
    required List<String> schemes,
    required String androidStoreUrl,
    required String iosStoreUrl,
  }) async {
    if (kIsWeb) {
      return const OfficeLaunchResult(
        success: false,
        message: 'Peluncuran aplikasi lokal tidak didukung di web browser.',
      );
    }

    try {
      if (Platform.isWindows) {
        // Use cmd /c start "" command to allow Windows App Paths resolution for MS Office
        final result = await Process.run('cmd', ['/c', 'start', '', windowsCommand]);
        if (result.exitCode == 0) {
          debugPrint('[OfficeLauncher] Successfully launched $name ($windowsCommand)');
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
        for (final pkg in androidPackages) {
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
        for (final scheme in schemes) {
          final uri = Uri.parse(scheme);
          if (await canLaunchUrl(uri)) {
            final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
            if (launched) {
              return OfficeLaunchResult(
                success: true,
                message: 'Berhasil membuka $name.',
              );
            }
          }
        }

        // 3. Fallback: Open Google Play Store page so user can install the app
        final storeUri = Uri.parse(androidStoreUrl);
        await launchUrl(storeUri, mode: LaunchMode.externalApplication);
        return OfficeLaunchResult(
          success: false,
          openedStore: true,
          message: '$name belum terinstal. Membuka Google Play Store untuk mengunduh...',
        );
      } else if (Platform.isIOS) {
        // 1. Try URI schemes via url_launcher
        for (final scheme in schemes) {
          final uri = Uri.parse(scheme);
          if (await canLaunchUrl(uri)) {
            final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
            if (launched) {
              return OfficeLaunchResult(
                success: true,
                message: 'Berhasil membuka $name.',
              );
            }
          }
        }

        // 2. Fallback: Open App Store link
        final storeUri = Uri.parse(iosStoreUrl);
        await launchUrl(storeUri, mode: LaunchMode.externalApplication);
        return OfficeLaunchResult(
          success: false,
          openedStore: true,
          message: '$name belum terinstal. Membuka App Store untuk mengunduh...',
        );
      } else if (Platform.isMacOS) {
        final result = await Process.run('open', ['-a', macAppName]);
        if (result.exitCode == 0) {
          return OfficeLaunchResult(success: true, message: 'Berhasil membuka $name.');
        } else {
          return OfficeLaunchResult(
            success: false,
            message: 'Gagal membuka $name di macOS. Pastikan aplikasi telah terinstal.',
          );
        }
      } else if (Platform.isLinux) {
        final parts = linuxCommand.split(' ');
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
