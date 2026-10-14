import 'package:ara_desktop/services/office_document_service.dart';
import 'package:ara_desktop/services/office_launcher_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OfficeDocumentService.detectKind', () {
    test('detects kind from file name extension', () {
      expect(OfficeDocumentService.detectKind(fileName: 'Jawaban Essay.DOCX'), OfficeDocumentKind.word);
      expect(OfficeDocumentService.detectKind(fileName: 'nilai.xls'), OfficeDocumentKind.excel);
      expect(OfficeDocumentService.detectKind(fileName: 'presentasi.pptx'), OfficeDocumentKind.powerpoint);
    });

    test('detects kind from URL path ignoring query string', () {
      final url = Uri.parse('https://ara-assessment.com/files/template.xlsx?token=abc#x');
      expect(OfficeDocumentService.detectKind(url: url), OfficeDocumentKind.excel);
    });

    test('detects kind from MIME type with parameters', () {
      expect(
        OfficeDocumentService.detectKind(
          mimeType: 'application/vnd.openxmlformats-officedocument.presentationml.presentation; charset=binary',
        ),
        OfficeDocumentKind.powerpoint,
      );
      expect(OfficeDocumentService.detectKind(mimeType: 'application/msword'), OfficeDocumentKind.word);
    });

    test('returns null for non-Office files', () {
      expect(OfficeDocumentService.detectKind(fileName: 'soal.pdf', mimeType: 'application/pdf'), isNull);
      expect(OfficeDocumentService.detectKind(url: Uri.parse('https://ara-assessment.com/assess/login')), isNull);
    });
  });

  group('OfficeDocumentService.isOfficeDocumentUrl', () {
    test('only matches http(s) links to Office files', () {
      expect(OfficeDocumentService.isOfficeDocumentUrl(Uri.parse('https://a.com/x/tugas.docx')), isTrue);
      expect(OfficeDocumentService.isOfficeDocumentUrl(Uri.parse('http://a.com/x/data.XLSX?d=1')), isTrue);
      expect(OfficeDocumentService.isOfficeDocumentUrl(Uri.parse('https://a.com/ujian/soal')), isFalse);
      expect(OfficeDocumentService.isOfficeDocumentUrl(Uri.parse('blob:https://a.com/1234')), isFalse);
      expect(OfficeDocumentService.isOfficeDocumentUrl(Uri.parse('ms-word:ofe|u|https://a.com/a.docx')), isFalse);
    });
  });

  group('OfficeDocumentService.fileNameFromContentDisposition', () {
    test('parses quoted filename', () {
      expect(
        OfficeDocumentService.fileNameFromContentDisposition('attachment; filename="Lembar Jawaban.docx"'),
        'Lembar Jawaban.docx',
      );
    });

    test('prefers RFC 5987 filename* and decodes it', () {
      expect(
        OfficeDocumentService.fileNameFromContentDisposition(
          "attachment; filename=\"fallback.docx\"; filename*=UTF-8''Tugas%20Akhir%202026.docx",
        ),
        'Tugas Akhir 2026.docx',
      );
    });

    test('parses unquoted filename and handles missing header', () {
      expect(OfficeDocumentService.fileNameFromContentDisposition('attachment; filename=rekap.xlsx'), 'rekap.xlsx');
      expect(OfficeDocumentService.fileNameFromContentDisposition(null), isNull);
      expect(OfficeDocumentService.fileNameFromContentDisposition('inline'), isNull);
    });
  });

  group('OfficeDocumentService.resolveFileName', () {
    test('uses suggested name first', () {
      expect(
        OfficeDocumentService.resolveFileName(
          suggested: 'jawaban.docx',
          contentDisposition: 'attachment; filename="other.docx"',
          url: Uri.parse('https://a.com/download/123'),
        ),
        'jawaban.docx',
      );
    });

    test('falls back to Content-Disposition, then URL path segment', () {
      expect(
        OfficeDocumentService.resolveFileName(
          contentDisposition: 'attachment; filename="slide.pptx"',
          url: Uri.parse('https://a.com/download/123'),
        ),
        'slide.pptx',
      );
      expect(
        OfficeDocumentService.resolveFileName(url: Uri.parse('https://a.com/files/Data%20Nilai.xlsx')),
        'Data Nilai.xlsx',
      );
    });

    test('appends extension from MIME type when missing', () {
      expect(
        OfficeDocumentService.resolveFileName(
          url: Uri.parse('https://a.com/download/123'),
          mimeType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        ),
        '123.docx',
      );
    });

    test('uses a safe default when nothing is available', () {
      expect(OfficeDocumentService.resolveFileName(mimeType: 'application/vnd.ms-excel'), 'dokumen.xls');
    });
  });

  group('OfficeDocumentService.sanitizeFileName', () {
    test('removes illegal characters and path traversal', () {
      expect(OfficeDocumentService.sanitizeFileName('../../etc/passwd'), '_.._etc_passwd');
      expect(OfficeDocumentService.sanitizeFileName('a:b*c?"d<e>f|g.docx'), 'a_b_c__d_e_f_g.docx');
      expect(OfficeDocumentService.sanitizeFileName('   '), 'dokumen');
    });

    test('limits length while keeping the extension', () {
      final result = OfficeDocumentService.sanitizeFileName('${'a' * 300}.pptx');
      expect(result.length, 120);
      expect(result.endsWith('.pptx'), isTrue);
    });
  });

  group('OfficeDocumentService.mimeTypeFor & appFor', () {
    test('maps Office extensions to MIME types', () {
      expect(
        OfficeDocumentService.mimeTypeFor('a.xlsx'),
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
      expect(OfficeDocumentService.mimeTypeFor('a.ppt'), 'application/vnd.ms-powerpoint');
    });

    test('falls back to provided MIME type, then wildcard', () {
      expect(OfficeDocumentService.mimeTypeFor('a.pdf', fallback: 'application/pdf'), 'application/pdf');
      expect(OfficeDocumentService.mimeTypeFor('a.bin', fallback: 'application/octet-stream'), '*/*');
      expect(OfficeDocumentService.mimeTypeFor('noext'), '*/*');
    });

    test('maps kinds to the matching Office app config', () {
      expect(OfficeDocumentService.appFor(OfficeDocumentKind.word), same(OfficeAppConfig.word));
      expect(OfficeDocumentService.appFor(OfficeDocumentKind.excel), same(OfficeAppConfig.excel));
      expect(OfficeDocumentService.appFor(OfficeDocumentKind.powerpoint), same(OfficeAppConfig.powerPoint));
      expect(OfficeAppConfig.word.androidPackages.first, 'com.microsoft.office.word');
      expect(OfficeAppConfig.excel.schemes.first, 'ms-excel://');
    });
  });
}
