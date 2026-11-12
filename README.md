# RAVEN — Record · Archive · Visualise · Edit · Notes

RAVEN is a Flutter-first audio workspace for recording, organising, reviewing and annotating audio. It is designed for musicians, teachers, preachers, interviewers and everyday users who need a dependable recorder without needing to understand file management.

> **Implementation status:** this repository is a working development baseline, not a certified release. `dart analyze lib` currently reports **0 errors** (a handful of style infos remain). Android debug APK builds have been exercised on a Windows development PC; Windows desktop builds still need Visual Studio with the **Desktop development with C++** workload. Treat any reported diagnostic as work to resolve before release.
>
> **Background playback:** fully wired via `just_audio_background` + `AudioServiceActivity`. Media notification with artwork, lock-screen controls and Bluetooth headset buttons work in debug and release builds. ProGuard rules explicitly keep `com.ryanheise.audioservice.*` so R8 minification in release builds does not strip the manifest-referenced service and receiver.

### Quick build commands

```powershell
# Android debug APK (arm64 only, fastest)
flutter build apk --debug --target-platform android-arm64 --android-skip-build-dependency-validation

# Android release APK (minified + resource-shrunk, arm64 + armv7)
flutter build apk --release --android-skip-build-dependency-validation

# Android App Bundle for Play Store
flutter build appbundle --release --android-skip-build-dependency-validation

# Windows desktop
flutter build windows --release
```

`--android-skip-build-dependency-validation` suppresses Flutter's *"Gradle/AGP/Kotlin version will soon be dropped"* warnings. It only silences the version check — it does not change the build. Upgrade Gradle (≥ 9.1.0), AGP (≥ 9.0.1) and Kotlin (≥ 2.3.20) when convenient, then drop the flag.

## Product principles

- **Capture first:** recording starts without asking the user to create a project first. RAVEN creates a stable project ID and session automatically.
- **One project, one identity:** project IDs are independent of names and categories. Renaming or moving a project must never rename or move the audio files.
- **Keep originals safe:** notes, bookmarks and generated material are separate from the source audio. Do not overwrite originals with AI output or destructive processing.
- **Simple by default:** use plain-language explanations and recommended defaults; reveal technical parameters when users need them.
- **Private by default:** recordings are kept in app-private storage. AI is optional; user-supplied provider keys and explicit consent are required for each notes request.
- **Recoverable changes:** the project index uses temporary writes and a backup file; deletion is routed through Trash before permanent removal.

## Current capabilities in this codebase

- Responsive Flutter interface with Home, Library and Settings navigation. The Home screen shows the number of library items and the number of categories, plus recent recordings. The Library sidebar has a branded header, pill-style filters with live per-category counts, and a shortcut to manage categories.
- **Standalone recordings:** one tap starts a private standalone take immediately, without creating a project. A standalone recording can be resumed, renamed, encrypted, shared and later promoted to a full project from its menu, at which point it gains notes, attachments and multi-session support.
- One-tap capture workflow, pause/resume, save/discard, duration display and waveform-level visualization. On Android, an active recording is kept alive by a microphone-type foreground service with a visible notification offering Pause/Resume and Stop actions. The Player screen microphone action can continue an existing project by appending a new session while preserving the stable project ID, title, notes, bookmarks and earlier audio paths. Protected projects must be decrypted before another session is appended.
- M4A/AAC, MP3, WAV and FLAC format choices (actual encoder support depends on the target platform/plugin; MP3 encoding uses the FFmpeg `libmp3lame` encoder).
- Adjustable sample rate and bitrate plus optional platform voice processing requests.
- Project library with search, rename, favourites, Trash/restore and permanent delete. Renaming a project now also renames its on-device folder (`<Title>-<id>`) and rewrites every audio/master/public path it contains; renaming a take renames its audio file on disk too (soft-failing safely when a file is locked, so display renames always succeed).
- Audio playback, seeking across a single continuous project timeline, playback-speed control, editable project notes and timeline bookmarks. Project sessions remain individually playable, shareable, renameable and manageable from their own action menus. Continued recordings are merged into a single master file after Stop **on desktop**; on Android the sessions are played as one continuous timeline instead (see *Master audio and FFmpeg*). Library import accepts supported audio files (M4A, MP3, WAV and FLAC) as resumable standalone recordings, as well as portable RAVEN project bundles.
- **Background playback & media notifications:** audio playback survives navigating between screens and minimizing or locking the device via `just_audio_background` and a global `PlaybackService` singleton. System media notifications and lock-screen controls (playback status, artwork, scrubbable progress bar, play/pause) keep active playback controllable anywhere. Bluetooth headset and wired headset media buttons are handled by `MediaButtonReceiver`. Background playback works in both debug and release APKs — ProGuard rules protect the `com.ryanheise.audioservice` classes that R8 would otherwise strip.
- **Streamlined PIN Lock UX:** users can require or remove the RAVEN PIN lock on individual recordings directly from the Library card action menu or the standalone player without opening a project tab. Unlocking a PIN-protected recording starts playback immediately in the standalone player without forcing conversion into a multi-track project.
- **Instant save with background encoding:** tapping Save on a long recording no longer blocks on FFmpeg. The captured WAV is committed immediately as the session's real audio (playable, shareable, resumable) and the transcode to the configured format (M4A/MP3/FLAC) runs in the background via `BackgroundEncodeService`. Jobs run one at a time, re-read the project record before committing, follow on-disk renames, abort safely if the take was replaced, and never lose audio on failure. The resume-merge and post-save auto-publish wait for pending encodes so they never race a swap.
- **Trimming with format preservation:** any take can be trimmed from the Player screen take-menu or the standalone recording's three-dot menu (`TrimEditor`). The editor offers a draggable timeline with unlimited cut regions anywhere in the middle of the recording, a visual keep/cut strip, selection preview, undo and reset. Saving always asks: **Replace original** or **Save as new take** — the original is only destroyed when the user explicitly chooses so. `AudioTrimService` renders each kept region with FFmpeg at the source's format, bitrate and sample rate (an M4A stays M4A, a WAV stays WAV) and joins segments losslessly; trims share a mutex with background encodes so file rewrites never collide.
  - **Timeline interaction:** the start/end handles are locked to the gesture that grabbed them (`_activeHandle`), so dragging one handle past the midpoint never flips control to the other handle mid-drag. A minimum 0.1% span is always preserved, and taps move the nearest handle.
  - **Composable edits:** *Cut selection* removes the highlighted span from the keep-set; *Keep only* cuts everything outside it. Both can be applied repeatedly, so a user can carve out many pieces from many places in one session. *Undo cut* removes the last edit and *Reset* clears everything.
  - **No surprises:** the keep/cut strip under the timeline shows every surviving region (blue) against every removed gap (red), and the header shows the predicted trimmed length before saving.
  - **Preview:** *Play selection* plays only the selected span and stops automatically at its end; the playhead is drawn on the timeline while previewing.
  - **Save choices:** *Replace original* writes the trimmed audio in place and deletes the old file only after the project record is durably updated; *Save as new take* keeps the original untouched and inserts the trimmed copy as a new session (named `<take> · trimmed`) right after the source take. A standalone that gains a trimmed copy is promoted to a multi-part recording.
- **Timeline bookmarks:** add a bookmark from the app bar, from the player controls, or from the bookmarks card. The dialog shows the exact timestamp and which recording part it belongs to, pauses playback while open, and resumes afterwards. Bookmarks are sorted by time, can be renamed or deleted, jump-and-play on tap, and are drawn as markers on a mini timeline strip. Each bookmark stores its `sessionId`, so a multi-session project always knows which part a bookmark belongs to; orphaned bookmarks are pruned when a part is deleted.
- **Notes as real `.txt` files:** *Save .txt* writes a UTF-8 (with BOM) text file into the project folder at `projects/<id>/notes/<title> notes.txt`, so it opens correctly in Notepad, Word, Google Docs or any text editor and is included in project exports. A private copy is always written; the share sheet is offered from the confirmation snackbar.
- **Attachments:** files and images can be attached to a project, previewed, shared, and removed individually or in bulk with select-all multi-select.
- English/French UI strings and a first-run guided tour with explanations of recording, library, settings and privacy. The tour can be replayed from Settings.
- Secure-storage vault and provider REST clients for OpenRouter, OpenAI API and Gemini API; users can configure models, test connections and manage keys. Notes AI actions require confirmation and never send audio in the current implementation.
- Optional app-wide PIN gate stored using platform secure storage with a salted PBKDF2-HMAC-SHA256 verifier. Individual recordings can require the same RAVEN PIN before opening. This is an app-access lock, not file encryption. Per-recording public-folder control physically moves a project folder between app-private storage and `/storage/emulated/0/Music/RAVEN/<name>-<id>/` on Android (requires `MANAGE_EXTERNAL_STORAGE`, requested lazily on the first "Make public" action). On Windows/Linux the public root is `Downloads/RAVEN/`.
- **Public visibility MOVES, never copies:** standalone recordings and multi-take projects use the same move-based flow (`ProjectRepository.toggleVisibility`). The whole project folder is relocated between private app storage and the public RAVEN root, and every session/master path is rewritten — device storage stays flat with no duplicate public copy. Legacy `publicCopyLocation` files created by older builds are deleted automatically on the next visibility change, and the resume-merge no longer re-publishes a copy after merging. The confirmation dialogs and the Settings switch state this explicitly.
- Recovery-aware JSON project index and category manifests. At startup, RAVEN also makes a best-effort cleanup of abandoned plaintext playback caches left after an interrupted process.
- **Interrupted-recording recovery:** if a process is force-killed mid-recording, the session is kept as a draft. Draft sessions appear in the Library as "Interrupted draft — review audio"; opening one repairs the WAV header of a partial PCM16 recording (recomputing RIFF/data sizes) and lets the user save or discard it. Drafts are excluded from playback shortcuts, export and continue-recording flows until recovered.
- Direct sharing of a recording via the platform share sheet. Encrypted recordings are decrypted to temporary files for sharing and those temporaries are removed afterwards; the master file is shared when valid, otherwise sessions are shared.

## Architecture and data model

### Application layers

- `lib/main.dart` — app bootstrap, theme, responsive navigation and first-run tour.
- `lib/models/raven_project.dart` — serializable project, audio-session and timeline-bookmark models.
- `lib/screens/` — UI only: Home, Recorder, Library, Player and Settings.
- `lib/services/project_repository.dart` — filesystem persistence, project index, backup/recovery and category manifests. Also owns the move-based public/private folder relocation (`toggleVisibility`), on-disk project rename (`renameProject`) and take-file rename (`renameSessionFile`).
- `lib/services/playback_service.dart` — shared, app-wide audio player singleton powering continuous background playback and WAV duration parsing.
- `lib/services/audio_encryption_service.dart` — authenticated AES-GCM encryption with a per-recording password-derived key and PBKDF2; the password is never persisted.
- `lib/services/audio_protection_service.dart` — project-level encrypt/decrypt orchestration, including removal of the master file on encryption and refusal to encrypt while a public copy exists.
- `lib/services/audio_share_service.dart` — platform share-sheet export of a recording (master preferred, session fallback) with temporary decryption of protected sources.
- `lib/services/wav_recovery_service.dart` — PCM16 WAV header repair for recordings interrupted by process death.
- `lib/services/recording_notification_service.dart` — Android method-channel bridge for the recording foreground service and its pause/stop notification actions.
- `android/app/src/main/kotlin/com/raven/raven/RecordingForegroundService.kt` — microphone-type foreground service keeping an active recording alive with a visible, actionable notification.
- `lib/services/ai_key_vault.dart` — OS secure-storage access for user-provided credentials.
- `lib/services/app_preferences.dart` — non-secret preferences (language, theme, quality options, app-lock toggle and tour completion).
- `lib/services/app_lock_service.dart` — PIN verifier derivation and verification using secure storage; no plaintext PIN is persisted.
- `lib/services/attachment_service.dart` — sanitized attachment picking, project attachment listing and deletion.
- `lib/services/document_export_service.dart` — UTF-8-with-BOM encoding and safe `.txt` file naming for project notes.
- `lib/services/project_archive_service.dart` — safe ZIP bundle export/import with path-traversal guards, staged extraction and ID remapping.
- `lib/services/audio_visibility_service.dart` — legacy single-file public-copy publishing to Android MediaStore or Windows Downloads (kept for cleanup of copies created by older builds; new visibility changes use the move-based `ProjectRepository.toggleVisibility`).
- `lib/services/audio_timeline.dart` — deterministic mapping between internal sessions and the single user-facing playback timeline.
- `lib/services/audio_merge_service.dart` — FFmpeg-backed, validated master-audio creation from retained source sessions (desktop only; see *Master audio and FFmpeg*).
- `lib/services/background_encode_service.dart` — singleton background transcode queue (WAV capture → M4A/MP3/FLAC) with duplicate-job guards, stale-input detection, fresh-record rebasing before commit, a shared mutex for other file-rewriting services and `waitForProject()` used by the resume-merge and auto-publish paths.
- `lib/services/audio_trim_service.dart` — multi-region FFmpeg trimming that merges/clamps user regions, renders each kept segment with the source's codec tier and sample rate, joins segments with the concat demuxer, and serializes with background encodes through the shared mutex.
- `lib/widgets/trim_editor.dart` — full-screen trim editor: draggable timeline handles locked to the active gesture, cut-selection / keep-only composition, unlimited cuts anywhere in the recording, keep/cut visualization strip, selection playback preview with playhead, undo/reset, and an explicit save-choice dialog (replace original vs. save as a new take).
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
│   └── <name>-<short-uuid>/  # canonical private project folder
│       ├── sessions/         # source audio or encrypted audio sessions
│       ├── notes/            # exported .txt notes (UTF-8 with BOM)
│       ├── attachments/      # reserved for imported files/images
│       ├── exports/          # reserved for project exports
│       └── metadata/         # reserved for project metadata/history
└── categories/
    └── <safe-category-name>/
        └── <project-uuid>.json  # lightweight pointer/manifest only
```

**Public project folders (Android):** when a project is made public, its entire folder is **physically moved** (not copied) to `/storage/emulated/0/Music/RAVEN/<name>-<short-uuid>/`. This requires `MANAGE_EXTERNAL_STORAGE` on Android 11+ (prompted lazily on first "Make public"). On Android 10 and below, `WRITE_EXTERNAL_STORAGE` + `requestLegacyExternalStorage` achieve the same without a runtime prompt. Making a project private moves the folder back to app-private storage. Resuming, adding notes, managing attachments, and deleting all work directly on the folder at its current location — no copies are involved.

**Windows / Linux public root:** `<Downloads>/RAVEN/<name>-<short-uuid>/`.

## App lock and private recordings

RAVEN stores recordings under the application-support directory by default. On Android, this is app-private storage and recordings normally do not appear in public music folders or a general file manager. This is different from encrypting a file: app-private storage limits ordinary access by other apps, while the app PIN gate prevents someone casually opening RAVEN on an already-unlocked device.

- Enable **Lock RAVEN with a PIN** in Settings and choose 4–12 digits. The PIN is not stored in plaintext; RAVEN stores a random salt and a PBKDF2-HMAC-SHA256 verifier in platform secure storage.
- Individual projects can require that PIN before opening. Existing projects remain compatible because the field defaults to false when absent from older project JSON.
- The app lock is not a substitute for the phone/computer account lock, and it does not encrypt audio files against someone with filesystem/debug access or a compromised device.
- Turning off the app-wide lock keeps the verifier in secure storage so recordings individually locked with the PIN do not become inaccessible. If the PIN is forgotten, there is no automatic recovery flow yet; keep a backup of important recordings.
- Use a recording's three-dot menu and select **Lock audio with a password** to encrypt just that recording; this is separate from the app PIN. RAVEN requests a password and confirmation, derives an AES-256-GCM key using PBKDF2, and does not store the password. The password cannot be reset: forgetting it makes the protected audio unrecoverable. Playback asks for the password and temporarily decrypts audio into app storage. Encryption currently buffers whole files in memory, so very large recordings may use substantial RAM; keep a separate backup and test with small files first.

The Player screen includes a managed public-copy control for supported targets. “Show” creates a separate user-visible copy, while “Hide” removes the managed copy and leaves the private original in place. This is not encryption; users should not assume deleting a copy securely erases flash storage.

## Optional AI assistant

AI is opt-in and uses the user's own provider account. RAVEN does not include a shared API key or pay provider bills. Provider credentials are stored in `flutter_secure_storage`, not in `SharedPreferences`, project JSON, notes, logs, or project exports.

Supported providers in this build:

- **OpenRouter** — one OpenAI-compatible endpoint for a broad model catalogue. Create a key at https://openrouter.ai/keys, choose the exact model ID shown in its catalogue, and set a key spending limit. The default model is `meta-llama/llama-3.3-70b-instruct:free`; availability and free-tier limits are controlled by OpenRouter, and many other models require credits.
- **OpenAI API** — create a key at https://platform.openai.com/api-keys. A ChatGPT subscription is separate from API billing; check usage and billing before using it.
- **Google Gemini API** — create/manage a key at https://aistudio.google.com/app/apikey and check project quotas and billing. The default model is `gemini-2.0-flash`; model names are editable and should be checked against Google's current model catalogue: https://ai.google.dev/gemini-api/docs/models.

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

Open an existing project and tap the microphone action. RAVEN appends a new internal source session to the same stable project ID and title. After Stop, it first saves the source session to the project index, then (on desktop) uses the maintained `ffmpeg_kit_flutter_new_audio` package to create a single continuous master file. The merge re-encodes to the project's current output format (AAC/M4A, MP3 via `libmp3lame`, PCM/WAV, or FLAC) so sessions with different recording settings can be normalized. A pending file is validated before being renamed into place. Original session files are retained as recovery sources; they are not deleted after a successful merge. Playback prefers the master file and falls back to the continuous session playlist if the master is missing or merge fails. The global seek bar and bookmarks remain tied to the combined timeline. The master is removed when project audio is encrypted so it cannot remain as an unencrypted copy; after decryption, RAVEN attempts to rebuild it.

### Master audio and FFmpeg (Android APK size)

`ffmpeg_kit_flutter_new_audio` ships **no prebuilt Android binary** in this project's configuration, but its Gradle module still pulls `ffmpeg-kit-audio` AARs for arm64/armv7/x86_64 — roughly 20–30 MB of native libraries that would never be used. To keep the APK small:

- `android/app/build.gradle.kts` excludes the `com.antonkarpenko:ffmpeg-kit-audio` module from every `implementation`/`api` configuration.
- `AudioMergeService.isSupported` returns `false` on Android, so the merge is skipped and playback uses the continuous session playlist (the same fallback path used when a master is missing or corrupt).
- The same file also limits ABIs to `arm64-v8a` and `armeabi-v7a`, enables R8 minification and resource shrinking for release builds, and strips duplicate `META-INF` license/notice files.

If you later need on-device merging on Android, remove the Gradle `exclude` block and add a package that actually bundles an Android FFmpeg binary; expect the APK to grow substantially.

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
flutter build apk --debug --android-skip-build-dependency-validation
```

Release builds (minified, resource-shrunk, arm64 + armv7):

```powershell
flutter build apk --release --android-skip-build-dependency-validation
flutter build appbundle --release --android-skip-build-dependency-validation
```

To build for a single ABI (smaller and faster):

```powershell
flutter build apk --release --target-platform android-arm64 --android-skip-build-dependency-validation
```

If a dependency does not support the selected platform/version, record the exact diagnostic, check that package's supported-platform matrix and pin a compatible version rather than suppressing the diagnostic. Run `flutter pub outdated` when dependency resolution fails, but upgrade packages deliberately and re-test.

## Android setup notes

The Android app scaffold and plugin configuration are in `android/`. Recording notifications require notification permission on Android versions that request it. Android also requires the microphone foreground-service type for continuing a recording while RAVEN is backgrounded.

### APK size and build configuration

- **ABIs:** `arm64-v8a` and `armeabi-v7a` only. Add `x86_64` back in `android/app/build.gradle.kts` if you need an x86 emulator.
- **Release shrinking:** `isMinifyEnabled` and `isShrinkResources` are on, with rules in `android/app/proguard-rules.pro`.
- **FFmpeg:** excluded from the Android variant (see *Master audio and FFmpeg*).
- **Version warnings:** Flutter warns that Gradle 8.14.3, AGP 8.11.1 and Kotlin 2.2.20 will soon be unsupported. Build with `--android-skip-build-dependency-validation` until you upgrade them.
- **SDK XML warning:** *"This version only understands SDK XML versions up to 3 but an SDK XML file of version 4 was encountered"* means Android Studio and the command-line tools are from different releases. It is harmless; update the command-line tools to match Android Studio to silence it.

### Permissions

| Permission | Purpose |
|---|---|
| `RECORD_AUDIO` | Microphone capture |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MICROPHONE` | Recording foreground service |
| `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | Background audio playback service (Android 14+) |
| `POST_NOTIFICATIONS` | Recording and playback notifications |
| `WAKE_LOCK` | Keep audio alive when screen turns off |
| `MANAGE_EXTERNAL_STORAGE` | Move project folders into `Music/RAVEN/` (Android 11+, prompted lazily) |
| `WRITE_EXTERNAL_STORAGE` `maxSdkVersion="28"` | Same capability on Android 10 and below |
| `READ_EXTERNAL_STORAGE` | Read shared storage on Android ≤ 12 |

### Background playback (Android)

Background playback is powered by `just_audio_background` + `AudioServiceActivity`:

- `MainActivity` extends `AudioServiceActivity` (from `com.ryanheise.audioservice`). This registers the `AudioService` foreground service automatically and must not be changed to a plain `FlutterActivity`.
- `AudioService` and `MediaButtonReceiver` are declared in `AndroidManifest.xml` and kept by ProGuard rule `-keep class com.ryanheise.audioservice.**`. Without this rule R8 minification strips them from release builds, silently breaking background audio and media button handling.
- `PlaybackService` holds a single `AudioPlayer` for the app's lifetime. The player is never disposed per-screen, so playback continues when navigating away from `PlayerScreen`.
- `JustAudioBackground.init()` is called at the top of `main()`, before any `AudioPlayer` is created.
- Media notification shows the project title, session name, album art (project attachment or RAVEN logo) and a scrubbable seek bar. Lock-screen controls and Bluetooth headset buttons dispatch to the same player.

To verify after a release build: start playback, press Home, confirm the media notification appears and play/pause works from the notification shade and lock screen. `adb logcat | grep -i "audioservice\|just_audio\|raven"` shows any service failures.

### Saving notes as `.txt` on Android

Notes are written to the project folder (`projects/<id>/notes/`) and are therefore private to the app. To open them outside RAVEN, use the **Share** action in the confirmation snackbar, or export the project bundle. The `publishDocument` method channel in `MainActivity.kt` can copy a text file into the public `Documents/RAVEN` folder on Android 10+ if you want a user-visible copy; it is not called by default so notes stay inside the project.

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
8. Check editable `.txt` notes export (file appears in `projects/<id>/notes/`, opens in Notepad with correct accents), bookmark add/rename/delete/jump, French UI, first-run tour and tour replay.
9. Test long recordings, low storage, denied permissions, missing files, interrupted writes and app process termination; confirm the interrupted draft appears in the Library, its WAV header is repaired on open, and it can be saved or discarded.
10. Test project bundle export/import with long audio, attachments, special characters, missing source files and interrupted import; verify the imported project receives a new ID and stays private.
11. **Background playback (release build):** install a release APK, start playing a recording, press Home — confirm media notification appears with artwork and seek bar. Play/pause from the notification and lock screen. Press Back from the Player screen and confirm audio continues. `adb logcat | grep -i audioservice` must be silent (no crashes).
12. **Public folder (Android 11+):** make a project public — confirm the "Allow RAVEN to access all files" settings screen appears on first use. Grant, return to app, verify `Music/RAVEN/<name>-<id>/sessions/` exists in the Files app. Make private — folder disappears from Music. Deny permission — snackbar shows the actionable message, nothing moved.
13. **Public folder blocked cases:** try to make an encrypted project public (should fail with encryption message); try to make a PIN-locked project public (should fail with PIN message).
14. **Background encoding:** save a long recording in MP3/M4A mode — confirm the recorder closes immediately, the take is playable right away as WAV, the encoded file replaces it within a couple of minutes with a completion snackbar, and the library refreshes. Save two recordings back-to-back and confirm the second encodes after the first. Rename or bookmark-edit a project while its encode runs and confirm no edit is lost.
15. **Trimming:** trim the middle of a recording (Cut selection), then trim head and tail (Keep only); verify the keep-strip prediction matches the final duration; preview the selection before saving; save as a new take (original untouched, new take appears) and again with Replace original (old file removed, duration updated); confirm the trimmed file keeps the source's format and quality tier. Repeat once while a background encode is pending on the same take and confirm the trim waits its turn.

## Scope still to finish

This codebase does not yet constitute the entire planned RAVEN product. Remaining larger features include backup hardening, advanced audio editing/noise removal, transcription and AI processing of audio, additional platform-specific public-copy support, streaming-safe encryption, and end-to-end recovery verification on every platform. Interrupted-recording draft recovery is wired end to end but still needs device verification across Android versions and storage conditions. Portable project export/import is wired into the Player/Library UI but requires round-trip testing with real archives, imported audio and large attachments.
