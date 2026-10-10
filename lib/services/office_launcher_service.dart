import 'dart:io';
import 'package:flutter/foundation.dart';

class OfficeLaunchResult {
  final bool success;
  final String message;

  const OfficeLaunchResult({required this.success, required this.message});
}

class OfficeLauncherService {
  static final OfficeLauncherService _instance = OfficeLauncherService._internal();
  factory OfficeLauncherService() => _instance;
  OfficeLauncherService._internal();

  /// Launch Microsoft Word
  Future<OfficeLaunchResult> launchWord() async {
    return _launchApp(
      name: 'Microsoft Word',
      windowsCommand: 'winword',
      macAppName: 'Microsoft Word',
      linuxCommand: 'libreoffice --writer',
    );
  }

  /// Launch Microsoft Excel
  Future<OfficeLaunchResult> launchExcel() async {
    return _launchApp(
      name: 'Microsoft Excel',
      windowsCommand: 'excel',
      macAppName: 'Microsoft Excel',
      linuxCommand: 'libreoffice --calc',
    );
  }

  /// Launch Microsoft PowerPoint
  Future<OfficeLaunchResult> launchPowerPoint() async {
    return _launchApp(
      name: 'Microsoft PowerPoint',
      windowsCommand: 'powerpnt',
      macAppName: 'Microsoft PowerPoint',
      linuxCommand: 'libreoffice --impress',
    );
  }

  Future<OfficeLaunchResult> _launchApp({
    required String name,
    required String windowsCommand,
    required String macAppName,
    required String linuxCommand,
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
