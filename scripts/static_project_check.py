"""Dependency-free structural checks for RAVEN when Flutter/Dart are unavailable.

This is not a Dart analyzer and cannot validate type resolution or plugin APIs.
Run: python scripts/static_project_check.py
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
errors = []

pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
if "name: raven" not in pubspec:
    errors.append("pubspec.yaml must declare package name raven")
if "flutter: '>=3.47.5'" not in pubspec:
    errors.append("pubspec.yaml must retain Flutter >=3.47.5 constraint")
if "ffmpeg_kit_flutter_new_audio: ^2.5.7" not in pubspec:
    errors.append("pubspec.yaml must include the selected maintained FFmpeg audio package")

# Verify local relative Dart imports resolve. Package imports are handled by pub.
for dart in (ROOT / "lib").rglob("*.dart"):
    source = dart.read_text(encoding="utf-8")
    for match in re.finditer(r"import\s+'(\.{1,2}/[^']+)'\s*;", source):
        target = (dart.parent / match.group(1)).resolve()
        if not target.exists():
            errors.append(f"{dart.relative_to(ROOT)} imports missing file {match.group(1)}")

required = [
    "lib/main.dart",
    "lib/models/raven_project.dart",
    "lib/services/project_repository.dart",
    "lib/services/scheduled_recording_service.dart",
    "lib/services/audio_encryption_service.dart",
    "lib/services/audio_timeline.dart",
    "lib/services/app_lock_service.dart",
    "test/audio_timeline_test.dart",
    "test/ai_provider_service_test.dart",
    "lib/services/ai_key_vault.dart",
    "lib/services/ai_provider_service.dart",
    "lib/services/audio_merge_service.dart",
    "lib/services/audio_visibility_service.dart",
    "android/app/src/main/kotlin/com/raven/raven/MainActivity.kt",
    "lib/screens/recorder_screen.dart",
    "lib/screens/library_screen.dart",
    "lib/screens/player_screen.dart",
    "lib/screens/settings_screen.dart",
    "lib/screens/scheduled_recordings_screen.dart",
    "android/app/src/main/kotlin/com/raven/raven/ScheduledRecordingReceiver.kt",
    "assets/images/raven_logo.png",
    "README.md",
    "ARCHITECTURE_REVIEW.md",
    "BUILD_STATUS.md",
]
for relative in required:
    if not (ROOT / relative).is_file():
        errors.append(f"Missing required project file: {relative}")

manifest = (ROOT / "android/app/src/main/AndroidManifest.xml").read_text(encoding="utf-8")
for required_manifest_entry in [
    "android.permission.SCHEDULE_EXACT_ALARM",
    "android.permission.POST_NOTIFICATIONS",
    ".ScheduledRecordingReceiver",
    ".ScheduledRecordingBootReceiver",
]:
    if required_manifest_entry not in manifest:
        errors.append(f"Android manifest is missing: {required_manifest_entry}")

if errors:
    print("RAVEN structural check FAILED:")
    for error in errors:
        print(f" - {error}")
    sys.exit(1)
print("RAVEN structural check passed: required files and relative imports exist.")
print("This check does not replace flutter analyze, flutter test, or a real build.")
