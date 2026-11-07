# RAVEN code audit and correction report

**Audit package:** RAVEN Flutter source tree  
**Report date:** 29 October 2026  
**Status:** Corrections and structural checks completed; compile/runtime verification remains blocked by missing Flutter/Dart SDKs.

## Summary

I inspected the current RAVEN source tree and made targeted corrections in high-risk areas. The work preserves the existing app architecture and feature set rather than replacing it with a reduced sample. The delivered ZIP is a **corrected source project, not a compiled APK or release build**.

## Corrections included in this build

### Playback and recording recovery

- Playback tries the project's master recording first, but if the master is missing or the audio player rejects it, RAVEN clears the stale master reference and falls back to the retained session playlist.
- Recovered drafts measure the final source session independently rather than reusing the first playlist item's duration.
- Master creation writes to a pending output, checks the result, keeps a rollback copy until replacement succeeds, and preserves original session recordings as recovery sources.
- A failed merge is reported as a fallback to sequential session playback, rather than being described as a successful single-file merge.

### Audio protection and privacy

- Protection conversion prepares the replacement files before changing the project's session paths.
- The player switches to the replacement files before old source files are deleted. If validation or metadata persistence fails, generated outputs are cleaned up best-effort and original data is retained where possible.
- When a protected project is opened, RAVEN attempts to remove stale plaintext sources and masters and warns when that cleanup cannot be confirmed.
- Portable export rejects projects marked as protected and now also rejects session paths ending in `.ravenenc`, guarding against inconsistent metadata.
- **Security limitation:** the current AES-GCM protection implementation reads entire files into memory. It is experimental and should not be trusted for large or irreplaceable recordings. Decrypted playback requires temporary plaintext files, and cleanup is best-effort; this is not equivalent to a hardened, streaming encrypted audio pipeline.

### Project import/export and data integrity

- Connected the Library import action to ZIP selection, staged validation, private-storage installation, repository update, and user feedback.
- Imported audio paths are remapped to the new project directory, and each imported project receives a fresh stable ID. Device-specific public-copy references, encryption state, per-project PIN requirement, and master cache references are not carried into the portable import.
- Bundle import now rejects path traversal before path normalization, absolute paths, drive-qualified paths, empty segments, and NUL characters. Added a dedicated regression test file for safe paths and malicious traversal cases.
- Export removes device-specific paths from the portable manifest and skips reproducible master/rollback outputs.
- Added `path` as a direct dependency rather than relying on a transitive package import.

### AI provider requests

- Reviewed OpenAI-compatible and Gemini request construction, key loading, timeout handling, response-size limits, JSON parsing, non-success HTTP errors, and credential redaction in surfaced provider errors.
- Redirect following is disabled so a provider API key is not forwarded to an unexpected redirect destination.
- AI note actions explicitly ask permission before sending notes; they do not upload audio in these actions. Results can be reviewed before saving separately or replacing the notes.
- Updated the default Gemini model to `gemini-3.8-flash`, which Google's current model documentation lists as stable as of this report date: https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash
- **Verification limitation:** no live API call was made. Provider/model availability, billing, network behavior, and secure-storage behavior still need a real-device test with the user's own API key.

### Scheduled recording

- The scheduling implementation stores a requested local date/time, requests notification and exact-alarm permissions on Android, and handles cancel/restore plumbing.
- The due notification is silent and visible. It does not include the chosen project title on the lock screen.
- **Platform limitation:** when RAVEN is already active and unlocked, the app can start a due recording. When Android has RAVEN backgrounded or closed, the user must tap the visible notification; the broadcast receiver itself does not turn on the microphone. On Windows and other targets, the app needs to stay open for the schedule to trigger.
- Reboot/force-stop, notification settings, microphone permission, and manufacturer battery-management behavior require physical-device testing.

### Project identity, UI, and settings

- Rename continues to use the persistent project ID and does not change the recording/session paths, notes, bookmarks, or master path. A regression test covers those invariants.
- Checked key UI wiring for the Library import entry point, AI request consent/review flow, scheduled-recording entry point, and Settings refresh after provider/model changes.
- Corrected stale build-status text that said portable import UI was still missing after the latest source added it.

## Checks actually run

The following checks were run in the available environment after the latest edits:

1. `python scripts/deep_static_audit.py` — **passed**. It parses `pubspec.yaml`, checks imported package names against direct dependencies, lexically checks balanced delimiters across Dart/Kotlin source files, parses the Android manifest, checks key permissions/components, and verifies selected source invariants.
2. `python scripts/static_project_check.py` — **passed**. It checks required project files and relative Dart imports.
3. Android manifest XML parsing — **passed** as part of the deep static audit.
4. ZIP integrity (`unzip -t`) — run on the final delivered archive.

## Checks not run (do not treat these as passed)

Flutter and Dart executables are not installed in the current environment. As a result, these were **not run**:

- `flutter pub get`
- `flutter analyze`
- `flutter test` (including the new regression test)
- Android Gradle/Kotlin compilation or APK creation
- Windows desktop compilation
- UI tests, audio capture/playback tests, long-recording tests, and scheduled-recording tests on a physical device
- live AI API calls

Structural checks catch missing files/imports, malformed manifest XML, delimiter problems and selected regressions; they do **not** replace Dart type analysis or platform compilation.

## Known limitations and next verification steps

1. Install Flutter 3.47.5 or compatible SDK on the development PC, add `flutter/bin` to PATH, then run `scripts/verify_windows.bat` from the project root.
2. Resolve any dependency/plugin compilation errors. Validate that all dependencies support each requested target; an Android success does not imply the Windows build works.
3. Run the existing test suite plus `test/project_archive_safety_test.dart`.
4. Test Android recording on a real device: permissions, pause/resume, interruption recovery, audio merge, bad/missing master fallback, protected audio, plaintext cleanup, app lock and schedule notification behavior.
5. Test Windows runner and plugin support independently.
6. Before any public release, replace the whole-file encryption implementation with a vetted streaming approach or clearly keep the experimental protection feature disabled for large recordings; test key loss, app reinstall, restore and backup scenarios.

**Bottom line:** this build includes targeted code corrections and passed the structural checks available here. It is not yet proven to compile or to work end-to-end on Android/Windows, and I have not represented unrun tests as successful.
