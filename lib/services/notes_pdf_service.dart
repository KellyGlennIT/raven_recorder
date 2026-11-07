import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/raven_project.dart';

/// Creates a share/print-ready notes PDF. It does not modify project notes.
class NotesPdfService {
  Future<Uint8List> buildPdf(RavenProject project, {String locale = 'en'}) async {
    final document = pw.Document();
    final dateLabel = DateFormat('yyyy-MM-dd HH:mm', locale).format(project.updatedAt);
    document.addPage(
      pw.MultiPage(
        build: (context) => <pw.Widget>[
          pw.Text(project.title, style: const pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 6),
          pw.Text('RAVEN · ${project.category} · $dateLabel'),
          pw.Divider(),
          pw.Text(project.notes.trim().isEmpty ? 'No notes added.' : project.notes),
          if (project.bookmarks.isNotEmpty) ...<pw.Widget>[
            pw.SizedBox(height: 18),
            pw.Text('Bookmarks', style: const pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
            ...project.bookmarks.map((bookmark) => pw.Padding(
                  padding: const pw.EdgeInsets.only(top: 4),
                  child: pw.Text('${_time(bookmark.positionMs)}  ·  ${bookmark.label}'),
                )),
          ],
        ],
      ),
    );
    return document.save();
  }

  Future<void> printOrShare(RavenProject project, {String locale = 'en'}) async {
    final bytes = await buildPdf(project, locale: locale);
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'RAVEN-${_safeName(project.title)}-notes.pdf');
  }

  String _time(int ms) {
    final seconds = ms ~/ 1000;
    return '${(seconds ~/ 3600).toString().padLeft(2, '0')}:${((seconds % 3600) ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  String _safeName(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '-').replaceAll(RegExp(r'-+'), '-');
    final trimmed = cleaned.replaceAll(RegExp(r'^-+|-+$'), '');
    if (trimmed.isEmpty) return 'project';
    return trimmed.length > 48 ? trimmed.substring(0, 48) : trimmed;
  }
}
