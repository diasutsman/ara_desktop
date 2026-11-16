import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Mirrors every `debugPrint` line into a daily log file on desktop so field issues
/// (blank WebView, Office launch, kiosk watchdog blocks) can be diagnosed after the fact.
///
/// Windows: %LOCALAPPDATA%\ARA Assessment\logs\ara_YYYY-MM-DD.log (kept 7 days).
class FileLogger {
  FileLogger._();

  static IOSink? _sink;
  static Timer? _flushTimer;

  static String? get logDirectory {
    if (kIsWeb) return null;
    if (Platform.isWindows) {
      final base = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
      return '$base\\ARA Assessment\\logs';
    }
    if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
      return '$home/.ara_assessment/logs';
    }
    return null;
  }

  static void install() {
    final dirPath = logDirectory;
    if (dirPath == null || _sink != null) return;
    try {
      final dir = Directory(dirPath)..createSync(recursive: true);
      _pruneOldLogs(dir);
      final now = DateTime.now();
      final day = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final file = File('${dir.path}${Platform.pathSeparator}ara_$day.log');
      _sink = file.openWrite(mode: FileMode.append);
      _sink!.writeln('===== ARA start ${now.toIso8601String()} pid=$pid os=${Platform.operatingSystemVersion} =====');

      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        original(message, wrapWidth: wrapWidth);
        try {
          _sink?.writeln('${DateTime.now().toIso8601String()} $message');
        } catch (_) {}
      };
      _flushTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        _sink?.flush().catchError((Object _) {});
      });
    } catch (e) {
      debugPrint('[FileLogger] install failed: $e');
    }
  }

  static void _pruneOldLogs(Directory dir) {
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      for (final entity in dir.listSync()) {
        if (entity is File && entity.path.endsWith('.log') && entity.statSync().modified.isBefore(cutoff)) {
          entity.deleteSync();
        }
      }
    } catch (_) {}
  }

  static Future<void> close() async {
    _flushTimer?.cancel();
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
  }
}
