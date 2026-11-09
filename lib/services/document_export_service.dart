import 'dart:convert';

/// Helpers for writing plain-text documents (project notes) that open cleanly
/// in Notepad, Word, Google Docs or any text editor.
///
/// Notes are stored **inside the project folder** (`projects/<id>/notes/`), so
/// they belong to the project and are included in project exports. This class
/// only provides the encoding and file-name rules; the caller decides where the
/// file lives.
class DocumentExportService {
  const DocumentExportService();

  /// UTF-8 with a byte-order mark. Notepad and Word then detect the encoding
  /// reliably and show accented French text correctly; every modern editor
  /// ignores the BOM.
  static List<int> utf8WithBom(String content) =>
      <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(content)];

  /// Turns a project title into a safe `.txt` file name.
  static String safeFileName(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final base = cleaned.isEmpty ? 'RAVEN notes' : cleaned;
    final limited = base.length > 80 ? base.substring(0, 80) : base;
    return limited.toLowerCase().endsWith('.txt') ? limited : '$limited.txt';
  }
}
