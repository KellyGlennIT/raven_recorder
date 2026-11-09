# RAVEN — Record · Archive · Visualise · Edit · Notes

RAVEN is a Flutter-first audio workspace for recording, organising, reviewing and annotating audio. It is designed for musicians, teachers, preachers, interviewers and everyday users who need a dependable recorder without needing to understand file management.

> **Implementation status:** this repository is a working development baseline, not a certified release. Flutter/Dart were not installed in the preparation environment, so `flutter analyze`, `flutter test`, and desktop/device builds could not be executed here. The dependency-free structural check is useful for missing files/imports only; it is not a compiler. Run `scripts/verify_windows.bat` on a Windows development PC. It generates the Windows desktop runner if it is absent, then runs dependency resolution, analysis, tests, Android debug APK build and Windows desktop build. A Windows build also needs Visual Studio with the Desktop development with C++ workload. Treat any reported diagnostic as work to resolve before release.

## Product principles

- **Capture first:** recording starts without asking the user to create a project first. RAVEN creates a stable project ID and session automatically.
- **One project, one identity:** project IDs are independent of names and categories. Renaming or moving a project must never rename or move the audio files.
- **Keep originals safe:** notes, bookmarks and generated material are separate from the source audio. Do not overwrite originals with AI output or destructive processing.
- **Simple by default:** use plain-language explanations and recommended defaults; reveal technical parameters when users need them.
- **Private by default:** recordings are kept in app-private storage. AI is optional; user-supplied provider keys and explicit consent are required for each notes request.
- **Recoverable changes:** the project index uses temporary writes and a backup file; deletion is routed through Trash before permanent removal.

## Current capabilities in this codebase

- Responsive Flutter interface with Home, Library and Settings navigation.
- **Standalone recordings:** one tap starts a private standalone take immediately, without creating a project. A standalone recording can be resumed, renamed, encrypted, shared and later promoted to a full project from its menu, at which point it gains notes, attachments and multi-session support.
- One-tap capture workflow, pause/resume, save/discard, duration display and waveform-level visualization. On Android, an active recording is kept alive by a microphone-type foreground service with a visible notification offering Pause/Resume and Stop actions. The Player screen microphone action can continue an existing project by appending a new session while preserving the stable project ID, title, notes, bookmarks and earlier audio paths. Protected projects must be decrypted before another session is appended.
- M4A/AAC, MP3, WAV and FLAC format choices (actual encoder support depends on the target platform/plugin; MP3 encoding uses the FFmpeg `libmp3lame` encoder).
- Adjustable sample rate and bitrate plus optional platform voice processing requests.
- Project library with search, rename, favourites, Trash/restore and permanent delete. Renaming changes the title stored against the stable project ID; it does not move or rename audio/session files, notes, bookmarks or the continuous master.
- Audio playback, seeking across a single continuous project timeline, playback-speed control, editable project notes, timeline bookmarks and PDF notes output. Continued recordings are automatically merged into a single master file after Stop, while original segments remain internally available for recovery. Playback uses the master when valid and falls back to the combined timeline if merging fails. Player export and Library import move portable project bundles, including source audio and attachments; imports get a new stable project ID and are kept private.
- English/French UI strings and a first-run guided tour with explanations of recording, library, settings and privacy. The tour can be replayed from Settings.
- Secure-storage vault and provider REST clients for OpenRouter, OpenAI API and Gemini API; users can configure models, test connections and manage keys. Notes AI actions require confirmation and never send audio in the current implementation.
- Optional app-wide PIN gate stored using platform secure storage with a salted PBKDF2-HMAC-SHA256 verifier. Individual recordings can require the same RAVEN PIN before opening. This is an app-access lock, not file encryption. Per-recording public-copy control can create/remove a managed copy in Android Music/RAVEN (Android 10+) or Windows Downloads/RAVEN while preserving the private original.
- Recovery-aware JSON project index and category manifests. At startup, RAVEN also makes a best-effort cleanup of abandoned plaintext playback caches left after an interrupted process.
- **Interrupted-recording recovery:** if a process is force-killed mid-recording, the session is kept as a draft. Draft sessions appear in the Library as "Interrupted draft — review audio"; opening one repairs the WAV header of a partial PCM16 recording (recomputing RIFF/data sizes) and lets the user save or discard it. Drafts are excluded from playback shortcuts, export and continue-recording flows until recovered.
- Direct sharing of a recording via the platform share sheet. Encrypted recordings are decrypted to temporary files for sharing and those temporaries are removed afterwards; the master file is shared when valid, otherwise sessions are shared.
- One-off scheduled recordings in Settings: choose a date/time and optional recording title, view/cancel scheduled items, and automatically start when RAVEN is active at the due time. On Android, when RAVEN is not active, a silent but visible notification is posted; tapping it opens RAVEN and starts the scheduled recording within a 15-minute grace window. This is notification-assisted, not covert background recording.

## Architecture and data model

### Application layers

- `lib/main.dart` — app bootstrap, theme, responsive navigation and first-run tour.
- `lib/models/raven_project.dart` — serializable project, audio-session and timeline-bookmark models.
- `lib/screens/` — UI only: Home, Recorder, Library, Player and Settings.
- `lib/services/project_repository.dart` — filesystem persistence, project index, backup/recovery and category manifests.
- `lib/services/audio_encryption_service.dart` — experimental authenticated AES-GCM file encryption exposed in Player; memory-heavy and not production-safe for large recordings.
- `lib/services/audio_protection_service.dart` — project-level encrypt/decrypt orchestration, including removal of the master file on encryption and refusal to encrypt while a public copy exists.
- `lib/services/audio_share_service.dart` — platform share-sheet export of a recording (master preferred, session fallback) with temporary decryption of protected sources.
- `lib/services/wav_recovery_service.dart` — PCM16 WAV header repair for recordings interrupted by process death.
- `lib/services/recording_notification_service.dart` — Android method-channel bridge for the recording foreground service and its pause/stop notification actions.
- `android/app/src/main/kotlin/com/raven/raven/RecordingForegroundService.kt` — microphone-type foreground service keeping an active recording alive with a visible, actionable notification.
- `lib/services/ai_key_vault.dart` — OS secure-storage access for user-provided credentials.
- `lib/services/app_preferences.dart` — non-secret preferences (language, theme, quality options, app-lock toggle and tour completion).
- `lib/services/scheduled_recording_service.dart` — persistent one-off schedules, due-time checks and the Android method-channel bridge.
- `lib/screens/scheduled_recordings_screen.dart` — schedule creation, date/time picker, upcoming schedules and cancellation.
- `android/app/src/main/kotlin/com/raven/raven/ScheduledRecordingReceiver.kt` — exact-alarm receiver that posts a silent, visible reminder; it does not itself activate the microphone.
- `lib/services/app_lock_service.dart` — PIN verifier derivation and verification using secure storage; no plaintext PIN is persisted.
- `lib/services/category_service.dart` — category listing, safe renaming and category reassignment/deletion without touching audio directories.
- `lib/services/attachment_service.dart` — sanitized attachment picking, project attachment listing and deletion.
- `lib/services/project_archive_service.dart` — safe ZIP bundle export/import with path-traversal guards, staged extraction and ID remapping.
- `lib/services/audio_visibility_service.dart` — optional public-copy publishing to Android MediaStore or Windows Downloads with verify/cleanup.
- `lib/services/notes_pdf_service.dart` — PDF generation/print/share.
- `lib/services/audio_timeline.dart` — deterministic mapping between internal sessions and the single user-facing playback timeline.
- `lib/services/audio_merge_service.dart` — FFmpeg-backed, validated master-audio creation from retained source sessions.
- `lib/services/ai_provider_service.dart` — opt-in REST integration for OpenRouter, OpenAI API, and Gemini API, with bounded prompts, timeouts, and provider error handling.
- `test/` — model, serialization, audio-timeline mapping, app-lock, archive-safety, AI-provider and WAV-recovery tests.

Screens should not directly invent file locations or serialize project JSON. Route persistence through `ProjectRepository`; keep platform APIs behind services; keep IDs stable; handle errors at the user-action boundary; never log secrets or audio contents.

### Private storage layout

The repository root is under the platform's application-support directory in a `raven` folder. A typical layout is:

```text
<application-support>/raven/
├── projects.json             # canonical project index
├── projects.json.bak         # last known-good index backup
├── projects.json.tmp         # in-progress index write / recovery candidate
├── projects/
│   └── <stable-project-uuid>/
│       ├── sessions/         # source audio or encrypted audio sessions
│       ├── notes/            # reserved for note attachments/exports
│       ├── attachments/      # reserved for imported files/images
│       ├── exports/          # reserved for project exports
│       └── metadata/         # reserved for project metadata/history
└── categories/
    └── <safe-category-name>/
        └── <project-uuid>.json  # lightweight pointer/manifest only
```

**Why category manifests instead of moving the project folder?** A recording may be renamed or recategorised. Audio paths remain stable under `projects/<uuid>/sessions`; category folders are indexes only. This prevents moving a category from breaking session paths. Empty child directories are created when a project folder is first created; feature data should only be written when it exists.

On Android, this app-support directory is private to the app sandbox and is not meant to be browsed directly in a generic file manager. On Windows it is under the application-support location for the current user. Use the Player export action to create a portable project bundle, and the Library archive button to import a `.zip` bundle. Uninstalling may remove private app data; keep separate backups of important projects.

## App lock and private recordings

RAVEN stores recordings under the application-support directory by default. On Android, this is app-private storage and recordings normally do not appear in public music folders or a general file manager. This is different from encrypting a file: app-private storage limits ordinary access by other apps, while the app PIN gate prevents someone casually opening RAVEN on an already-unlocked device.

- Enable **Lock RAVEN with a PIN** in Settings and choose 6–12 digits. The PIN is not stored in plaintext; RAVEN stores a random salt and a PBKDF2-HMAC-SHA256 verifier in platform secure storage.
- Individual projects can require that PIN before opening. Existing projects remain compatible because the field defaults to false when absent from older project JSON.
- The app lock is not a substitute for the phone/computer account lock, and it does not encrypt audio files against someone with filesystem/debug access or a compromised device.
- Turning off the app-wide lock keeps the verifier in secure storage so recordings individually locked with the PIN do not become inaccessible. If the PIN is forgotten, there is no automatic recovery flow yet; keep a backup of important recordings.
- The Player screen currently exposes an **experimental AES-GCM audio-encryption action**. It reads whole files into memory and may consume several times the file size while transforming the data; playback also decrypts protected sources into app-temporary plaintext files. This is not production-grade at-rest protection for long recordings. Do not use it on long/large or irreplaceable recordings until a streaming-safe format, temporary-file lifecycle, recovery and device testing are completed. The app PIN is an access barrier, not file encryption.

The Player screen includes a managed public-copy control for supported targets. “Show” creates a separate user-visible copy, while “Hide” removes the managed copy and leaves the private original in place. This is not encryption; users should not assume deleting a copy securely erases flash storage.

## Optional AI assistant

AI is opt-in and uses the user's own provider account. RAVEN does not include a shared API key or pay provider bills. Provider credentials are stored in `flutter_secure_storage`, not in `SharedPreferences`, project JSON, notes, logs, or project exports.

Supported providers in this build:

- **OpenRouter** — one OpenAI-compatible endpoint for a broad model catalogue. Create a key at https://openrouter.ai/keys, choose the exact model ID shown in its catalogue, and set a key spending limit. The initial model uses OpenRouter’s free-model router where available; availability and free-tier limits are controlled by OpenRouter, and many other models require credits.
- **OpenAI API** — create a key at https://platform.openai.com/api-keys. A ChatGPT subscription is separate from API billing; check usage and billing before using it.
- **Google Gemini API** — create/manage a key at https://aistudio.google.com/app/apikey and check project quotas and billing. The default model is `gemini-3.8-flash` (current stable model reference as of October 29, 2026); model names are editable and should be checked against Google's current model catalogue: https://ai.google.dev/gemini-api/docs/models.

Settings lets the user choose the provider, enter a model identifier, save the key, test the connection, and delete a saved key. The test makes a real small API request, so provider usage policies and possible charges apply. Model names, availability, limits, and prices change; treat the model field as editable rather than promising that one default stays valid forever.

Portable ZIP export/import currently assembles archive contents in memory; very large projects may use substantial RAM, especially on phones. Encrypted projects cannot be exported portably until a user-controlled backup/key migration design exists.

The project notes screen offers **Summarize**, **Organize and polish**, and **Translate** actions. Before each request, RAVEN asks permission and explains which provider receives the notes. These actions send text from the notes field only; they do not upload the recording audio. Results are shown for review and are not saved over the notes unless the user chooses Replace notes. AI remains optional and core recording works without a key. The current provider client supports text requests, not audio transcription or sending attachments.

Provider requests use HTTPS, a 45-second timeout, a 60,000-character prompt limit, and no automatic retries. The app does not intentionally log API keys or prompts. Direct API calls from a user device still mean the selected provider receives submitted text; users should avoid sending confidential content unless they accept that provider's terms. For production release, test key-redaction and provider-specific error handling with mocked responses as well as real provider accounts.

## Settings explained for everyday users

- **Sample rate (kHz):** how many audio samples are captured each second. 44.1 or 48 kHz are general-purpose choices; higher values can increase processing/storage needs and may not be supported everywhere.
- **Bitrate (kbps):** for compressed audio, more bits per second usually means a larger file and better quality. WAV/FLAC behavior depends on the encoder and platform.
- **Recording format:** M4A/AAC is compact; MP3 is widely compatible; WAV is uncompressed and larger; FLAC is lossless compression where supported.
- **Voice enhancement:** asks the platform recorder to apply available automatic gain, echo cancellation and noise suppression. Support and results vary by device; listen to a test recording.
- **Language:** changes RAVEN's interface labels between English and French. Some plugin/platform dialogs may follow the operating system language.

## Continue recording and automatic master merge

Open an existing project and tap the microphone action. RAVEN appends a new internal source session to the same stable project ID and title. After Stop, it first saves the source session to the project index, then uses the maintained `ffmpeg_kit_flutter_new_audio` package to create a single continuous master file. The merge re-encodes to the project's current output format (AAC/M4A, MP3 via `libmp3lame`, PCM/WAV, or FLAC) so sessions with different recording settings can be normalized. A pending file is validated before being renamed into place. Original session files are retained as recovery sources; they are not deleted after a successful merge. Playback prefers the master file and falls back to the continuous session playlist if the master is missing or merge fails. The global seek bar and bookmarks remain tied to the combined timeline. The master is removed when project audio is encrypted so it cannot remain as an unencrypted copy; after decryption, RAVEN attempts to rebuild it.

The FFmpeg audio package is LGPL-3.0. Follow its redistribution terms and ship the `licenses/ffmpeg_kit_flutter_new_audio/` notices generated beside the Windows executable when distributing a Windows build. Check the package's current platform matrix and license bundle before each release.

Do not continue into a protected project: its existing sessions use encrypted paths, so the current workflow intentionally requires the user to decrypt first. If a process is force-killed during recording, the project index contains a draft session pointing at the partial file; the Library marks it as an interrupted draft, and opening it runs the PCM16 WAV header repair before the user chooses to save or discard. Drafts stay out of normal playback, export and continue flows until recovered.

## Engineering references

The recording lifecycle follows Flutter’s official record-audio recipe for permission checks, start/pause/resume/stop and disposal: https://docs.flutter.dev/cookbook/audio/record. Package capability differences are platform-specific; verify them against the record package matrix: https://pub.dev/packages/record. Playback remains delegated to just_audio rather than implementing codecs in the UI: https://pub.dev/packages/just_audio.

## Windows development (Flutter 3.47.5)

Install Flutter 3.47.5, its bundled Dart SDK, Git and Visual Studio with **Desktop development with C++**. Open the repository root folder (`raven_recorder`) in VS Code.

```powershell
flutter --version
flutter doctor -v
flutter create --platforms=windows .
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

Build an Android debug APK with Android SDK/platform tools configured:

```powershell
flutter build apk --debug
```

If a dependency does not support the selected platform/version, record the exact diagnostic, check that package's supported-platform matrix and pin a compatible version rather than suppressing the diagnostic. Run `flutter pub outdated` when dependency resolution fails, but upgrade packages deliberately and re-test.

## Android setup notes

The Android app scaffold and plugin configuration are in `android/`. Scheduled recording requires notification permission and, where Android requests it, Alarms & reminders access. Android restricts starting microphone capture from a background alarm; RAVEN therefore starts automatically only while its UI is already active, and otherwise requires the user to tap the scheduled notification. The notification itself is silent but visible. Test this flow on physical devices across Android versions, including screen lock, app force-stop, battery restrictions, denied notifications, denied exact alarms, reboot restoration, and calls/notifications. Alarms cannot override the operating system’s force-stop behavior.

## Recording notifications on Android

While a recording is active, a microphone-type foreground service shows a visible notification with Pause/Resume and Stop actions so capture can continue when the app is backgrounded. The service only mirrors state; capture decisions stay in the Flutter recorder. Test notification actions, notification permission denial, background transition, and force-stop during recording on real devices.

## Test plan before release

1. `flutter pub get` succeeds with the chosen SDK.
2. `flutter analyze` has no errors; review every warning.
3. `flutter test` passes.
4. Windows app starts and can record/play on a configured microphone.
5. Android app records, pauses, resumes, saves, and recovers correctly on a real device.
6. Rename/favourite/category/trash/restore do not break session paths.
7. Encrypt/decrypt a small test file, compare the restored bytes with the original, reject a modified ciphertext, and test failure/restart scenarios before using important recordings.
8. Check notes PDF, French UI, first-run tour and tour replay.
9. Test long recordings, low storage, denied permissions, missing files, interrupted writes and app process termination; confirm the interrupted draft appears in the Library, its WAV header is repaired on open, and it can be saved or discarded.
10. Test project bundle export/import with long audio, attachments, special characters, missing source files and interrupted import; verify the imported project receives a new ID and stays private.

## Scope still to finish

This codebase does not yet constitute the entire planned RAVEN product. Remaining larger features include backup hardening, advanced audio editing/noise removal, transcription and AI processing of audio, additional platform-specific public-copy support, streaming-safe encryption, and end-to-end recovery verification on every platform. Interrupted-recording draft recovery is wired end to end but still needs device verification across Android versions and storage conditions. Portable project export/import is now wired into the Player/Library UI but requires round-trip testing with real archives and large attachments. Scheduled recording and the Android notification bridge are in source but still require Flutter analysis, tests, Android compilation and real-device verification before release. The Flutter/Dart toolchain was unavailable in the preparation environment, so compiler/device checks are not claimed as passed.
