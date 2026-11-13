import 'package:flutter_test/flutter_test.dart';
import 'package:raven/services/project_archive_service.dart';

void main() {
  group('portable project archive path validation', () {
    test('accepts ordinary relative paths and ZIP directory entries', () {
      expect(isSafeRelativeArchivePath('sessions/recording.m4a'), isTrue);
      expect(isSafeRelativeArchivePath('project_files/attachments/'), isTrue);
    });

    test('rejects traversal before normalization can hide it', () {
      expect(isSafeRelativeArchivePath('../outside.txt'), isFalse);
      expect(isSafeRelativeArchivePath('sessions/../outside.m4a'), isFalse);
      expect(isSafeRelativeArchivePath('sessions\\..\\outside.m4a'), isFalse);
    });

    test('rejects absolute, drive-qualified, and malformed paths', () {
      expect(isSafeRelativeArchivePath('/etc/passwd'), isFalse);
      expect(isSafeRelativeArchivePath('C:/outside.txt'), isFalse);
      expect(isSafeRelativeArchivePath('\\server\\share\\file'), isFalse);
      expect(isSafeRelativeArchivePath(''), isFalse);
      expect(isSafeRelativeArchivePath('sessions//recording.m4a'), isFalse);
    });
  });
}