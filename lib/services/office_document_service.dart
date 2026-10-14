import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'kiosk_security_service.dart';
import 'office_launcher_service.dart';

enum OfficeDocumentKind { word, excel, powerpoint }

/// Downloads documents linked from the ARA portal (with the WebView session cookies)
/// and opens them in the matching Microsoft Office app on Android & iOS.
///
/// - Android: native `openDocument` -> FileProvider content:// URI + ACTION_VIEW targeted
///   at the Word/Excel/PowerPoint package (falls back to any capable viewer).
/// - iOS: native `openDocument` -> UIDocumentInteractionController "Open in..." sheet
///   (iOS does not allow targeting a specific third-party app directly).
class OfficeDocumentService {
  static final OfficeDocumentService _instance = OfficeDocumentService._internal();
  factory OfficeDocumentService() => _instance;
  OfficeDocumentService._internal();

  static const MethodChannel _mobileChannel = MethodChannel('ara_desktop/mobile_kiosk');

  static const String _downloadFolderName = 'ara_documents';
  static const int _maxRedirects = 5;
  static const Duration _downloadTimeout = Duration(minutes: 2);
  static const Duration _cacheRetention = Duration(hours: 24);

  static const Map<String, OfficeDocumentKind> extensionKinds = {
    'doc': OfficeDocumentKind.word,
    'docx': OfficeDocumentKind.word,
    'xls': OfficeDocumentKind.excel,
    'xlsx': OfficeDocumentKind.excel,
    'ppt': OfficeDocumentKind.powerpoint,
    'pptx': OfficeDocumentKind.powerpoint,
  };

  static const Map<String, String> extensionMimeTypes = {
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint',
    'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  };

  /// Reverse lookup: MIME type -> canonical file extension.
  static final Map<String, String> mimeExtensions = {
    for (final e in extensionMimeTypes.entries) e.value: e.key,
  };

  bool _isBusy = false;

  /// True while a document is being downloaded (prevents duplicate downloads on double taps).
  bool get isBusy => _isBusy;

  // ---------------------------------------------------------------------------
  // Pure helpers (unit tested)
  // ---------------------------------------------------------------------------

  /// Returns the lower-case file extension of a file name or URL path (without query/fragment).
  static String? extensionOf(String? nameOrPath) {
    if (nameOrPath == null || nameOrPath.isEmpty) return null;
    var value = nameOrPath.split('?').first.split('#').first;
    final slash = value.lastIndexOf('/');
    if (slash >= 0) value = value.substring(slash + 1);
    final dot = value.lastIndexOf('.');
    if (dot <= 0 || dot == value.length - 1) return null;
    return value.substring(dot + 1).toLowerCase();
  }

  /// Normalizes a MIME type header value (`type/subtype; charset=...` -> `type/subtype`).
  static String? normalizeMimeType(String? mimeType) {
    if (mimeType == null) return null;
    final value = mimeType.split(';').first.trim().toLowerCase();
    return value.isEmpty ? null : value;
  }

  /// Detects the Office document kind from file name, URL path, or MIME type (in that order).
  static OfficeDocumentKind? detectKind({Uri? url, String? mimeType, String? fileName}) {
    final fromName = extensionKinds[extensionOf(fileName)];
    if (fromName != null) return fromName;
    if (url != null) {
      final fromUrl = extensionKinds[extensionOf(url.path)];
      if (fromUrl != null) return fromUrl;
    }
    final ext = mimeExtensions[normalizeMimeType(mimeType)];
    return ext == null ? null : extensionKinds[ext];
  }

  /// True when [url] is an http(s) link that points at a Word/Excel/PowerPoint file.
  static bool isOfficeDocumentUrl(Uri url) {
    final scheme = url.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    return extensionKinds.containsKey(extensionOf(url.path));
  }

  static OfficeAppConfig appFor(OfficeDocumentKind kind) {
    switch (kind) {
      case OfficeDocumentKind.word:
        return OfficeAppConfig.word;
      case OfficeDocumentKind.excel:
        return OfficeAppConfig.excel;
      case OfficeDocumentKind.powerpoint:
        return OfficeAppConfig.powerPoint;
    }
  }

  /// Replaces characters that are illegal in file names and limits the length (keeping the extension).
  static String sanitizeFileName(String name) {
    var cleaned = name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // Avoid hidden files / relative path tricks like "..".
    cleaned = cleaned.replaceAll(RegExp(r'^\.+'), '').trim();
    if (cleaned.isEmpty) return 'dokumen';

    const maxLength = 120;
    if (cleaned.length > maxLength) {
      final ext = extensionOf(cleaned);
      final suffix = ext == null ? '' : '.$ext';
      cleaned = cleaned.substring(0, maxLength - suffix.length) + suffix;
    }
    return cleaned;
  }

  /// Extracts the file name from a `Content-Disposition` header (RFC 6266 / RFC 5987).
  static String? fileNameFromContentDisposition(String? header) {
    if (header == null || header.isEmpty) return null;

    final extended = RegExp(r"""filename\*\s*=\s*([^']*)'[^']*'([^;]+)""", caseSensitive: false)
        .firstMatch(header);
    if (extended != null) {
      final raw = extended.group(2)!.trim().replaceAll('"', '');
      try {
        return Uri.decodeComponent(raw);
      } catch (_) {
        return raw;
      }
    }

    final quoted = RegExp(r'filename\s*=\s*"([^"]*)"', caseSensitive: false).firstMatch(header);
    if (quoted != null && quoted.group(1)!.trim().isNotEmpty) return quoted.group(1)!.trim();

    final plain = RegExp(r'filename\s*=\s*([^;]+)', caseSensitive: false).firstMatch(header);
    if (plain != null && plain.group(1)!.trim().isNotEmpty) return plain.group(1)!.trim();

    return null;
  }

  /// Picks the best file name: suggested name -> Content-Disposition -> last URL path segment.
  /// Appends the canonical extension from [mimeType] when the chosen name has none.
  static String resolveFileName({
    String? suggested,
    String? contentDisposition,
    Uri? url,
    String? mimeType,
  }) {
    String? candidate;
    if (suggested != null && suggested.trim().isNotEmpty) {
      candidate = suggested.trim();
    } else {
      candidate = fileNameFromContentDisposition(contentDisposition);
    }
    if ((candidate == null || candidate.isEmpty) && url != null && url.pathSegments.isNotEmpty) {
      final last = url.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
      if (last.isNotEmpty) {
        try {
          candidate = Uri.decodeComponent(last);
        } catch (_) {
          candidate = last;
        }
      }
    }

    var name = sanitizeFileName(candidate ?? 'dokumen');
    if (extensionOf(name) == null) {
      final ext = mimeExtensions[normalizeMimeType(mimeType)];
      if (ext != null) name = '$name.$ext';
    }
    return name;
  }

  /// MIME type for a local file, preferring the known Office mapping of its extension.
  static String mimeTypeFor(String fileName, {String? fallback}) {
    final known = extensionMimeTypes[extensionOf(fileName)];
    if (known != null) return known;
    final normalized = normalizeMimeType(fallback);
    if (normalized != null && normalized != 'application/octet-stream') return normalized;
    return '*/*';
  }

  // ---------------------------------------------------------------------------
  // Download & open
  // ---------------------------------------------------------------------------

  bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Downloads [url] using the WebView's cookies and opens it in the matching Office app.
  Future<OfficeLaunchResult> downloadAndOpen({
    required Uri url,
    String? suggestedFileName,
    String? mimeType,
    String? userAgent,
  }) async {
    if (!_isMobile) {
      return const OfficeLaunchResult(
        success: false,
        message: 'Membuka dokumen dari portal hanya didukung pada perangkat mobile.',
      );
    }

    final scheme = url.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return const OfficeLaunchResult(
        success: false,
        message: 'Dokumen ini dibuat langsung oleh halaman web dan tidak dapat dibuka di aplikasi Office. Silakan hubungi pengawas.',
      );
    }

    if (_isBusy) {
      return const OfficeLaunchResult(
        success: false,
        message: 'Dokumen lain sedang diunduh, mohon tunggu sebentar...',
      );
    }

    _isBusy = true;
    try {
      final downloaded = await _download(url: url, suggestedFileName: suggestedFileName, mimeType: mimeType, userAgent: userAgent)
          .timeout(_downloadTimeout);
      final fileName = downloaded.file.uri.pathSegments.last;
      final kind = detectKind(fileName: fileName, mimeType: downloaded.mimeType ?? mimeType, url: url);

      // During an exam only Office documents may leave the app (parity with the desktop whitelist).
      if (kind == null && KioskSecurityService().currentMode != AssessmentMode.normal) {
        unawaited(_safeDelete(downloaded.file.parent));
        return const OfficeLaunchResult(
          success: false,
          message: 'Selama ujian, hanya dokumen Word, Excel, dan PowerPoint yang dapat dibuka.',
        );
      }

      return await openLocalFile(
        downloaded.file.path,
        mimeType: mimeTypeFor(fileName, fallback: downloaded.mimeType ?? mimeType),
        kind: kind,
      );
    } on TimeoutException {
      return const OfficeLaunchResult(
        success: false,
        message: 'Waktu unduh dokumen habis. Periksa koneksi internet lalu coba lagi.',
      );
    } on HttpException catch (e) {
      debugPrint('[OfficeDocument] HTTP error: $e');
      return OfficeLaunchResult(success: false, message: 'Gagal mengunduh dokumen: ${e.message}');
    } catch (e) {
      debugPrint('[OfficeDocument] Failed to download/open $url: $e');
      return const OfficeLaunchResult(
        success: false,
        message: 'Gagal mengunduh dokumen. Periksa koneksi internet lalu coba lagi.',
      );
    } finally {
      _isBusy = false;
    }
  }

  /// Opens an already-downloaded local file through the native `openDocument` channel method.
  Future<OfficeLaunchResult> openLocalFile(
    String path, {
    required String mimeType,
    OfficeDocumentKind? kind,
  }) async {
    final app = kind == null ? null : appFor(kind);
    final appName = app?.name ?? 'aplikasi penampil dokumen';

    // Mark BEFORE leaving the app so the pause event is not counted as a violation.
    if (app != null) {
      KioskSecurityService().markOfficeSessionStarted();
    }

    try {
      final status = await _mobileChannel.invokeMethod<String>('openDocument', {
        'path': path,
        'mimeType': mimeType,
        'packages': app?.androidPackages ?? const <String>[],
      });
      debugPrint('[OfficeDocument] openDocument($path, $mimeType) -> $status');

      switch (status) {
        case 'opened':
          return OfficeLaunchResult(
            success: true,
            message: Platform.isIOS
                ? 'Pilih $appName untuk membuka dokumen.'
                : 'Membuka dokumen di $appName...',
          );
        case 'preview':
          // iOS: no installed app can open the file; it is shown in an in-app QuickLook preview.
          return OfficeLaunchResult(
            success: false,
            message: '$appName belum terinstal. Dokumen ditampilkan dalam mode pratinjau.',
          );
        case 'no_app':
          if (app != null) return await OfficeLauncherService().openStoreFor(app);
          return const OfficeLaunchResult(
            success: false,
            message: 'Tidak ada aplikasi yang dapat membuka dokumen ini.',
          );
        default:
          return OfficeLaunchResult(success: false, message: 'Gagal membuka dokumen di $appName.');
      }
    } on PlatformException catch (e) {
      debugPrint('[OfficeDocument] openDocument PlatformException: ${e.code} ${e.message}');
      return OfficeLaunchResult(success: false, message: 'Gagal membuka dokumen: ${e.message ?? e.code}');
    } on MissingPluginException {
      return const OfficeLaunchResult(
        success: false,
        message: 'Fitur membuka dokumen belum tersedia pada platform ini.',
      );
    }
  }

  Future<({File file, String? mimeType})> _download({
    required Uri url,
    String? suggestedFileName,
    String? mimeType,
    String? userAgent,
  }) async {
    final root = Directory('${(await getTemporaryDirectory()).path}/$_downloadFolderName');
    await root.create(recursive: true);
    unawaited(_cleanupOldDownloads(root));

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    if (userAgent != null && userAgent.isNotEmpty) client.userAgent = userAgent;

    try {
      var currentUrl = url;
      HttpClientResponse? response;

      // Follow redirects manually so cookies are re-resolved per host (never leak the
      // ara-assessment.com session cookie to a third-party redirect target).
      for (var hop = 0; hop <= _maxRedirects; hop++) {
        final request = await client.getUrl(currentUrl);
        request.followRedirects = false;
        final cookieHeader = await _cookieHeaderFor(currentUrl);
        if (cookieHeader != null) request.headers.set(HttpHeaders.cookieHeader, cookieHeader);

        response = await request.close();
        if (response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.drain<void>();
          if (location == null) throw const HttpException('Redirect tanpa tujuan');
          currentUrl = currentUrl.resolve(location);
          continue;
        }
        break;
      }

      if (response == null || response.isRedirect) {
        throw const HttpException('Terlalu banyak redirect');
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('Server merespons ${response.statusCode}', uri: currentUrl);
      }

      final responseMime = response.headers.contentType?.mimeType;
      final fileName = resolveFileName(
        suggested: suggestedFileName,
        contentDisposition: response.headers.value('content-disposition'),
        url: currentUrl,
        mimeType: responseMime ?? mimeType,
      );

      // Unique sub-folder per download so re-downloading never overwrites a file that is
      // still open in Word/Excel/PowerPoint.
      final folder = Directory('${root.path}/${DateTime.now().millisecondsSinceEpoch}');
      await folder.create(recursive: true);
      final file = File('${folder.path}/$fileName');
      await response.pipe(file.openWrite());

      debugPrint('[OfficeDocument] Downloaded ${await file.length()} bytes to ${file.path}');
      return (file: file, mimeType: responseMime ?? mimeType);
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> _cookieHeaderFor(Uri url) async {
    try {
      final cookies = await CookieManager.instance().getCookies(url: WebUri(url.toString()));
      if (cookies.isEmpty) return null;
      return cookies.map((c) => '${c.name}=${c.value}').join('; ');
    } catch (e) {
      debugPrint('[OfficeDocument] Unable to read cookies for $url: $e');
      return null;
    }
  }

  Future<void> _cleanupOldDownloads(Directory root) async {
    try {
      final now = DateTime.now();
      await for (final entity in root.list()) {
        if (entity is! Directory) continue;
        final stat = await entity.stat();
        if (now.difference(stat.modified) > _cacheRetention) {
          await _safeDelete(entity);
        }
      }
    } catch (e) {
      debugPrint('[OfficeDocument] Cache cleanup skipped: $e');
    }
  }

  Future<void> _safeDelete(FileSystemEntity entity) async {
    try {
      await entity.delete(recursive: true);
    } catch (_) {}
  }
}
