# RAVEN — Record · Archive · Visualise · Edit · Notes

RAVEN is a Flutter-first audio workspace for recording, organising, reviewing and annotating audio. It is designed for musicians, teachers, preachers, interviewers and everyday users who need a dependable recorder without needing to understand file management.

> **Implementation status:** this repository is a working development baseline, not a certified release. `flutter analyze` currently reports **no issues** and `flutter test` passes the full suite. Android debug APK builds have been exercised on a Windows development PC; Windows desktop builds still need Visual Studio with the **Desktop development with C++** workload. Treat any reported diagnostic as work to resolve before release.
>
> **Background playback:** fully wired via `just_audio_background` + `AudioServiceActivity`. Media notification with artwork, lock-screen controls and Bluetooth headset buttons work in debug and release builds. ProGuard rules explicitly keep `com.ryanheise.audioservice.*` so R8 minification in release builds does not strip the manifest-referenced service and receiver.
>
> **Storage model:** public visibility is a **move**, not a copy. A recording lives in exactly one place on the device — either app-private storage or the public RAVEN folder — so making a recording public never doubles its disk usage.
>
> **License:** RAVEN is distributed under the **GNU General Public License v3.0**. See [License](#license).

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

## Contents

- [Who RAVEN is for](#who-raven-is-for)
- [Everyday scenarios](#everyday-scenarios)
- [Capability map](#capability-map)
- [Product principles](#product-principles)
- [Current capabilities in this codebase](#current-capabilities-in-this-codebase)
- [Feature reference](#feature-reference)
- [Architecture and data model](#architecture-and-data-model)
- [App lock and private recordings](#app-lock-and-private-recordings)
- [Optional AI assistant](#optional-ai-assistant)
- [Settings explained for everyday users](#settings-explained-for-everyday-users)
- [Continue recording and automatic master merge](#continue-recording-and-automatic-master-merge)
- [Engineering references](#engineering-references)
- [Windows development (Flutter 3.47.5)](#windows-development-flutter-3475)
- [Android setup notes](#android-setup-notes)
- [Recording notifications on Android](#recording-notifications-on-android)
- [Test plan before release](#test-plan-before-release)
- [Contributing](#contributing)
- [License](#license)
- [Scope still to finish](#scope-still-to-finish)

## Who RAVEN is for

| Person | What they need | How RAVEN helps |
|---|---|---|
| **Musician / songwriter** | Capture takes fast, keep several versions, rehearse against earlier takes | One-tap standalone takes, continue-recording into the same project, trim away false starts, save amplified or cleaned copies, bookmarks on the parts that matter |
| **Teacher / lecturer** | Long lectures, lesson notes, sharing with students | Background recording with a Pause notification, automatic save, editable notes exported as `.txt`, project bundles for students, speed control for review |
| **Preacher / church team** | Reliable Sunday capture, sermon notes, a public copy for the media team | Interrupted-recording recovery, public folder in `Music/RAVEN`, notes + AI polish, USB/Bluetooth headset media buttons |
| **Journalist / interviewer** | Protect sources, work offline, keep a defensible original | App PIN gate, per-recording AES-GCM password encryption, originals never overwritten by edits, AI fully opt-in |
| **Student** | Record a class on a locked phone, re-listen later | Foreground-service recording, lock-screen playback, bookmarks, low storage footprint |
| **Everyday user** | Just press record and find it later | No project setup required, simple library with search and categories, Trash with automatic retention |

## Everyday scenarios

Each scenario below is implemented in this codebase; the section in brackets names the code or capability that backs it.

### 1. “I just want to record right now”

Open RAVEN and tap the record button on Home. A **standalone recording** starts immediately — no project name, no category, no confirmation dialog. You can still record when a microphone permission prompt appears once. When you stop, the take is saved to the library with a generated title (`Recording · <date>`) and is immediately playable. Later you can rename, favourite, categorise, lock with a PIN, encrypt with a password, make it public, share it, trim it, clean it, amplify it, or promote it into a full multi-session project. [Recorder screen, `StandaloneRecordingScreen`, `isStandalone` flag on `RavenProject`]

### 2. “I rehearse the same song and want the earlier takes”

Resume an existing recording from its menu or the microphone action in the Player. RAVEN appends a new *session* to the same stable project ID and keeps the earlier audio untouched. Each session is individually playable, renameable, shareable and deletable; the project as a whole has one continuous timeline with one seek bar and one set of bookmarks. A master file is merged automatically after Stop where FFmpeg supports it; otherwise the sessions play back as one continuous timeline. [Continue-recording flow, `AudioMergeService`, `AudioTimeline`]

### 3. “That was a false start — cut the first 12 seconds”

From the Player take menu or the standalone three-dot menu, open **Trim**. Drag the handles, tap *Cut selection* on the dead air, optionally *Keep only* on the part you want, preview the selection, then choose **Save as new take** (the original stays intact) or **Replace original** (the old file is deleted only after the index is durably updated). The rendered file keeps the source codec, bitrate tier and sample rate. [Trim editor, `AudioTrimService`]

### 4. “The room had a fan / the recording is too quiet”

- **Clean audio** applies `highpass=f=80,afftdn=nf=-25`: a rumble/AC-hum high-pass plus FFmpeg's FFT spectral denoiser. It replaces the take in place with a rendered copy, showing progress as it goes. [`AudioCleanService`]
- **Amplify** opens a sheet with a 1.0×–3.0× slider and renders the take through `volume` + `alimiter` (limiter) so quiet speech gets louder without clipping. The boosted audio is previewed before you decide; **Save amplified audio to this take** commits it. [`PlayerScreen._applyBoost`, `_saveAmplifiedTake`]

Both operations refuse to run on encrypted projects, write to a `.pending` file and only rename it into place after validation, and take the same mutex as background encodes so two processes never rewrite the same file. Cleaning keeps the source format (bits: AAC/MP3 keep their tier; WAV/FLAC stay lossless). Amplify previews are temporary — they are deleted on exit or at the next startup — and only become part of the recording when you tap save.

### 5. “I need to remember exactly where the chorus starts”

Add a bookmark from the app bar, the player controls or the bookmarks card. The dialog pauses playback, shows the exact timestamp and which part of a multi-session recording it belongs to, and resumes afterwards. Bookmarks sort by time, can be renamed or deleted, jump-and-play on tap, and are drawn as markers on a mini timeline. Each bookmark stores its `sessionId`, so a multi-session project always knows which part it belongs to; managing a multi-session project's take list prunes bookmarks whose part is gone. [Bookmarks model + timeline strip in `PlayerScreen`]

### 6. “I was recording a lecture and the phone was killed”

If the OS or the user force-stops RAVEN mid-recording, the session is preserved as a **draft**. It appears in the Library as *"Interrupted draft — review audio"*. Opening it repairs the RIFF/data sizes of the partial PCM16 WAV, then lets you save or discard. Drafts never appear in playback shortcuts or export, and never enter the continue-recording flow until recovered. [Draft handling, `WavRecoveryService`]

### 7. “I want the file in my phone's music folder”

Make a recording public. On Android the project folder is **moved** to `/storage/emulated/0/Music/RAVEN/<name>-<id>/`, so other players and the Files app can see it — and no second copy exists. Making it private moves it back. *Public audio by default* in Settings applies this to every new take, and Settings also offers bulk **Make all recordings public / private**. Encrypted and PIN-locked projects are refused with a clear message. [Move-based `ProjectRepository.toggleVisibility`, `AudioVisibilityService` for legacy cleanup]

### 8. “I want to send this to someone”

Use **Share** on a take or project: the master file is shared when valid, otherwise the individual sessions. Protected audio is decrypted into temporary files, shared, and those temporaries are deleted afterwards. To hand over a whole project — audio, notes, attachments and metadata — use **Export project bundle** (a ZIP with path-traversal guards, staged extraction and a fresh ID on import). [Audio share service, archive service]

### 9. “Someone else must not open RAVEN”

Two independent layers:

1. **RAVEN PIN** — a 4–12 digit app-access gate verified against a salted PBKDF2-HMAC-SHA256 verifier (120 000 iterations) in platform secure storage. Individual recordings can require the same PIN before opening.
2. **Audio encryption** — per-recording password → PBKDF2-derived AES-256-GCM key (210 000 iterations, random salt, nonce and MAC stored with the file). The password is never persisted; forgetting it makes the audio unrecoverable.

The app lock is a casual-access gate, not full-disk encryption. [App lock service, encryption service, protection service]

### 10. “Turn these notes into a summary or a translation”

The notes screen offers **Summarize**, **Organize and polish** and **Translate**. Each request asks for explicit consent first and explains which provider receives the text. Only the notes text is sent — never the audio. Results are shown for review and are only written back when you choose *Replace notes*. Your key lives in OS secure storage; responses are capped at a 60 000-character prompt and a 45-second timeout with no automatic retries. [AI provider service, key vault]

### 11. “Listen on the train with the screen off”

Playback lives in a global singleton, so it continues across navigation, backgrounding and screen lock. A media notification shows title, artwork, a scrubbable seek bar and play/pause; lock-screen and Bluetooth/wired headset buttons control the same player. [Background playback, `PlaybackService`]

### 12. “Back up everything before I reset the phone”

Settings → **Backup all recordings** streams the whole library — projects, audio, notes, attachments, encrypted files and the index — into a single ZIP written to temp storage (so a large library never has to fit in RAM), then opens the share sheet so it can go to Drive, Dropbox or a computer. [Project archive service `backupAllData`]

### 13. “I want to read the notes in Word or Google Docs”

**Save .txt** writes a UTF-8 (with BOM) file into `projects/<id>/notes/<title> notes.txt` — a private copy always, with the share sheet offered from the confirmation snackbar — so accents open correctly in Notepad, Word or Google Docs. The file is included in project exports. [Document export service]

### 14. “I keep recordings from many people / classes”

The Library groups recordings by **category** with live per-category counts in a pill filter row, search across titles, favourites, and a **Trash** with restore. Trash retention is configurable (7 / 14 / 30 / 60 / 90 days or *Never*) and expired items are purged automatically on startup. Renaming a project renames its folder `<Title>-<id>` and rewrites every audio/master/public path inside it; renaming a take renames the file on disk (soft-failing safely if the file is locked, so the display rename always succeeds).

### 15. “I want RAVEN in French”

Switch **Interface language** in Settings. All screens, dialogs, snackbars and the first-run guided tour are translated. The tour can be replayed at any time from Settings.

## Capability map

| Area | Capability | Where |
|---|---|---|
| Capture | One-tap standalone recording | Recorder screen, `isStandalone` |
| Capture | Multiple formats: M4A/AAC, MP3, WAV, FLAC | `record` package + settings |
| Capture | Sample rate (16 / 22.05 / 44.1 / 48 kHz) and bitrate (64–256 kbps) | `AppPreferences` |
| Capture | Voice processing request (AGC, echo cancel, noise suppress) | `record` `RecordConfig` |
| Capture | Pause / resume / save / discard, live waveform-level meter | Recorder screen |
| Capture | Foreground-service recording with notification actions | `RecordingForegroundService.kt` |
| Capture | Interrupted-draft recovery (WAV header repair) | `WavRecoveryService` |
| Organise | Projects, categories, favourites, search | Library screen, repository |
| Organise | Trash with retention + restore + permanent delete | Repository, settings |
| Organise | Multi-session projects with stable ID | `RavenProject.sessions` |
| Organise | Attachments (files and images) | `AttachmentService` |
| Playback | Continuous combined timeline, seek, speed control | `AudioTimeline`, `PlaybackService` |
| Playback | Background playback, media notification, lock screen, headset buttons | `just_audio_background` |
| Edit | Multi-region trim, replace or save as new take | `TrimEditor`, `AudioTrimService` |
| Edit | FFT noise removal (clean) | `AudioCleanService` |
| Edit | Volume amplify with limiter (preview + save) | `PlayerScreen._applyBoost` |
| Edit | Waveform image for the take / trim timeline | `WaveformService` |
| Annotate | Timeline bookmarks tied to sessions | `RavenBookmark` |
| Annotate | Editable notes, `.txt` export | `DocumentExportService` |
| Protect | App PIN gate + per-recording PIN | `AppLockService` |
| Protect | AES-256-GCM audio password encryption | `AudioEncryptionService` |
| Share | Platform share sheet, decrypted temporaries cleaned up | `AudioShareService` |
| Share | Project ZIP bundle export/import | `ProjectArchiveService` |
| Share | Whole-library backup ZIP | `ProjectArchiveService.backupAllData` |
| Storage | Move-based public/private folders | `ProjectRepository.toggleVisibility` |
| Recovery | Atomic index writes, `.bak` recovery, orphan cleanup | `ProjectRepository` |
| Utility | AI notes (summarize / polish / translate) | `AiProviderService` |
| Utility | English/French UI, guided tour, dark/light theme | `AppPreferences`, `main.dart` |

## Product principles

- **Capture first:** recording starts without asking the user to create a project first. RAVEN creates a stable project ID and session automatically.
- **One project, one identity:** project IDs are independent of names and categories. Renaming or moving a project must never rename or move the audio files.
- **Keep originals safe:** notes, bookmarks and generated material are separate from the source audio. Do not overwrite originals with AI output or destructive processing — destructive edits always ask first.
- **Simple by default:** use plain-language explanations and recommended defaults; reveal technical parameters when users need them.
- **Private by default:** recordings are kept in app-private storage. AI is optional; user-supplied provider keys and explicit consent are required for each notes request.
- **Recoverable changes:** the project index uses temporary writes and a backup file; deletion is routed through Trash before permanent removal.

## Current capabilities in this codebase

- Responsive Flutter interface with Home, Library and Settings navigation. The Home screen shows the number of library items and the number of categories, plus recent recordings. The Library sidebar has a branded header, pill-style filters with live per-category counts, and a shortcut to manage categories.
- **Standalone recordings:** one tap starts a private standalone take immediately, without creating a project. A standalone recording can be resumed, renamed, encrypted, shared and later promoted to a full project from its menu, at which point it gains notes, attachments and multi-session support.
- One-tap capture workflow, pause/resume, save/discard, duration display and waveform-level visualization. On Android, an active recording is kept alive by a microphone-type foreground service with a visible notification offering Pause/Resume and Stop actions. The Player screen microphone action can continue an existing project by appending a new session while preserving the stable project ID, title, notes, bookmarks and earlier audio paths. Protected projects must be decrypted before another session is appended.
- M4A/AAC, MP3, WAV and FLAC format choices (actual encoder support depends on the target platform/plugin; MP3 encoding uses the FFmpeg `libmp3lame` encoder).
- Adjustable sample rate and bitrate plus optional platform voice processing requests.
- Project library with search, rename, favourites, Trash/restore and permanent delete. Renaming a project also renames its on-device folder (`<Title>-<id>`) and rewrites every audio/master/public path it contains; renaming a take renames its audio file on disk too (soft-failing safely when a file is locked, so display renames always succeed).
- Audio playback, seeking across a single continuous project timeline, playback-speed control, editable project notes and timeline bookmarks. Project sessions remain individually playable, shareable, renameable and manageable from their own action menus. Continued recordings are merged into a single master file after Stop; on platforms without a working FFmpeg build the sessions are played as one continuous timeline instead (see *Master audio and FFmpeg*). Library import accepts supported audio files (M4A, MP3, WAV and FLAC) as resumable standalone recordings, as well as portable RAVEN project bundles.
- **Background playback & media notifications:** audio playback survives navigating between screens and minimizing or locking the device via `just_audio_background` and a global `PlaybackService` singleton. System media notifications and lock-screen controls (playback status, artwork, scrubbable progress bar, play/pause) keep active playback controllable anywhere. Bluetooth headset and wired headset media buttons are handled by `MediaButtonReceiver`. Background playback works in both debug and release APKs — ProGuard rules protect the `com.ryanheise.audioservice` classes that R8 would otherwise strip.
- **Streamlined PIN Lock UX:** users can require or remove the RAVEN PIN lock on individual recordings directly from the Library card action menu or the standalone player without opening a project tab. Unlocking a PIN-protected recording starts playback immediately in the standalone player without forcing conversion into a multi-track project.
- **Instant save with background encoding:** tapping Save on a long recording no longer blocks on FFmpeg. The captured WAV is committed immediately as the session's real audio (playable, shareable, resumable) and the transcode to the configured format (M4A/MP3/FLAC) runs in the background via `BackgroundEncodeService`. Jobs run one at a time, re-read the project record before committing, follow on-disk renames, abort safely if the take was replaced, and never lose audio on failure. The resume-merge and post-save auto-publish wait for pending encodes so they never race a swap.
- **Trimming with format preservation:** any take can be trimmed from the Player screen take-menu or the standalone recording's three-dot menu (`TrimEditor`). The editor offers a draggable timeline with unlimited cut regions anywhere in the middle of the recording, a visual keep/cut strip, selection preview, undo and reset. Saving always asks: **Replace original** or **Save as new take** — the original is only destroyed when the user explicitly chooses so. `AudioTrimService` renders each kept region with FFmpeg at the source's format, bitrate and sample rate (an M4A stays M4A, a WAV stays WAV) and joins segments losslessly; trims share a mutex with background encodes so file rewrites never collide.
- **Noise cleaning:** *Clean audio* on a take runs FFmpeg's FFT denoiser behind an 80 Hz high-pass to strip hum, hiss, fans and rumble, rendering straight to disk with live progress and swapping the cleaned file in atomically. It refuses encrypted projects and shares the encode mutex.
- **Amplify:** a 1.0×–3.0× slider renders the take through a limiter for preview, then *Save amplified audio to this take* commits it at the recording's own format and quality tier. Boosted files are temporary until saved and are cleaned up on exit or startup.
- **Timeline bookmarks:** add a bookmark from the app bar, from the player controls, or from the bookmarks card. The dialog shows the exact timestamp and which recording part it belongs to, pauses playback while open, and resumes afterwards. Bookmarks are sorted by time, can be renamed or deleted, jump-and-play on tap, and are drawn as markers on a mini timeline strip. Each bookmark stores its `sessionId`, so a multi-session project always knows which part a bookmark belongs to; orphaned bookmarks are pruned when a part is deleted.
- **Notes as real `.txt` files:** *Save .txt* writes a UTF-8 (with BOM) text file into the project folder at `projects/<id>/notes/<title> notes.txt`, so it opens correctly in Notepad, Word, Google Docs or any text editor and is included in project exports. A private copy is always written; the share sheet is offered from the confirmation snackbar.
- **Attachments:** files and images can be attached to a project, previewed, shared, and removed individually or in bulk with select-all multi-select.
- English/French UI strings and a first-run guided tour with explanations of recording, library, settings and privacy. The tour can be replayed from Settings.
- Secure-storage vault and provider REST clients for OpenRouter, OpenAI API and Gemini API; users can configure models, test connections and manage keys. Notes AI actions require confirmation and never send audio in the current implementation.
- Optional app-wide PIN gate stored using platform secure storage with a salted PBKDF2-HMAC-SHA256 verifier. Individual recordings can require the same RAVEN PIN before opening. This is an app-access lock, not file encryption. Per-recording public-folder control physically moves a project folder between app-private storage and `/storage/emulated/0/Music/RAVEN/<name>-<id>/` on Android (requires `MANAGE_EXTERNAL_STORAGE`, requested lazily on the first "Make public" action). On Windows/Linux the public root is `Downloads/RAVEN/`.
- **Public visibility MOVES, never copies:** standalone recordings and multi-take projects use the same move-based flow (`ProjectRepository.toggleVisibility`). The whole project folder is relocated between private app storage and the public RAVEN root, and every session/master path is rewritten — device storage stays flat with no duplicate public copy. Legacy `publicCopyLocation` files created by older builds are deleted automatically on the next visibility change, and the resume-merge no longer re-publishes a copy after merging. The confirmation dialogs and the Settings switch state this explicitly.
- **Whole-library backup:** Settings → *Backup all recordings* streams the entire library into one ZIP outside the RAVEN folder (so the archive never contains itself) and opens the share sheet for cloud or computer storage.
- Recovery-aware JSON project index and category manifests. At startup, RAVEN also makes a best-effort cleanup of abandoned plaintext playback caches left after an interrupted process.
- **Interrupted-recording recovery:** if a process is force-killed mid-recording, the session is kept as a draft. Draft sessions appear in the Library as "Interrupted draft — review audio"; opening one repairs the WAV header of a partial PCM16 recording (recomputing RIFF/data sizes) and lets the user save or discard it. Drafts are excluded from playback shortcuts, export and continue-recording flows until recovered.
- Direct sharing of a recording via the platform share sheet. Encrypted recordings are decrypted to temporary files for sharing and those temporaries are removed afterwards; the master file is shared when valid, otherwise sessions are shared.

## Feature reference

A closer look at how each tool behaves, what it refuses to do, and what the user is guaranteed. Plain-language labels are the English UI strings; the French UI mirrors them.

### Recording

| Feature | Behaviour | Safety guarantees |
|---|---|---|
| Start | Begins capture immediately; recording state survives screen navigation | Nothing is written to the index until Stop |
| Pause / resume | Pauses the stream without ending the session; mirrored in the Android notification | The paused file stays a single WAV until Stop |
| Stop → Save | Commits the WAV instantly, then transcodes in the background | A failed encode never loses the WAV; the job is retried on re-encode request |
| Discard | Deletes the session and its file | Confirmation dialog; nothing enters Trash |
| Quality | Sample rate 16 / 22.05 / 44.1 / 48 kHz, bitrate 64 / 96 / 128 / 192 / 256 kbps, format M4A / MP3 / WAV / FLAC | Unsupported combinations are rejected by the platform encoder and surfaced as an error, not a silent downgrade |
| Voice enhancement | Requests AGC, echo cancellation and noise suppression from the platform recorder | Device-dependent; the setting is advisory |

### Library and organisation

| Feature | Behaviour |
|---|---|
| Search | Case-insensitive match on project title |
| Categories | Pill filters with live counts; renaming keeps the folder pointer intact |
| Favourites | Toggle from the card; favourites sort to the top |
| Rename | Renames the project folder and rewrites all paths inside it; locked files fail softly |
| Trash | Items stay for the configured retention, then are purged; *Never* disables purging |
| Import | Portable RAVEN bundle, or a single audio file (M4A / MP3 / WAV / FLAC) as a resumable standalone |
| Export | ZIP bundle with audio, notes, attachments and index entries; imported projects always get a new ID and stay private |

### Playback

| Feature | Behaviour |
|---|---|
| Combined timeline | All sessions laid end-to-end; seeking maps through `AudioTimeline` |
| Per-take playback | Play one session from its menu without changing the combined position model |
| Speed control | Standard just_audio speed presets |
| Amplified preview | Boosted audio is a temporary file, deleted on exit or at startup |
| Media notification | Title, artwork (project attachment or RAVEN logo), scrub bar, play/pause |
| Interruption safety | A missing or corrupt master falls back to the session playlist |

### Editing

| Tool | Options | What is preserved |
|---|---|---|
| Trim | Cut selection, keep only, unlimited regions, undo, reset, preview | Codec, bitrate tier, sample rate; the original unless *Replace original* is chosen |
| Clean | Single FFmpeg FFT denoise profile (`highpass=f=80,afftdn=nf=-25`) | Format, stereo→mono normalisation, 16–48 kHz clamp |
| Amplify | 1.0×–3.0× with limiter at 0.95 | Format and bitrate tier of the take |

All three write to a `.pending` file first, validate the output, then rename into place; all three serialise through `BackgroundEncodeService.acquireMutex()`.

### Protection, sharing and recovery

| Layer | Mechanism | Limits users must know |
|---|---|---|
| App PIN | PBKDF2-HMAC-SHA256 verifier in secure storage | Not encryption; does not protect against device-level access |
| Recording PIN | Same verifier, checked before opening a project | Remembered as long as the verifier exists |
| Audio password | AES-256-GCM, PBKDF2-derived key, per-file salt/nonce/MAC | No recovery; whole file is buffered in memory today |
| Share | Master preferred, session fallback, decrypted temporaries | Shared text/audio leaves the device and is governed by the receiving app |
| Bundle export | Path-traversal-guarded ZIP with staged extraction | An encrypted project cannot be exported until a key-migration design exists |
| Draft recovery | RIFF/data-size recompute on partial PCM16 WAV | Only WAV captures can be repaired |

## Architecture and data model

### Application layers

- `lib/main.dart` — app bootstrap, theme, responsive navigation and first-run tour.
- `lib/models/raven_project.dart` — serializable project, audio-session and timeline-bookmark models.
- `lib/screens/` — UI only: Home, Recorder, Library, Player, Standalone recording and Settings.
- `lib/services/project_repository.dart` — filesystem persistence, project index, backup/recovery, category manifests and trash purging. Also owns the move-based public/private folder relocation (`toggleVisibility`), on-disk project rename (`renameProject`) and take-file rename (`renameSessionFile`).
- `lib/services/playback_service.dart` — shared, app-wide audio player singleton powering continuous background playback and WAV duration parsing.
- `lib/services/audio_encryption_service.dart` — authenticated AES-GCM encryption with a per-recording password-derived key and PBKDF2; the password is never persisted.
- `lib/services/audio_protection_service.dart` — project-level encrypt/decrypt orchestration, including removal of the master file on encryption and refusal to encrypt while a public copy exists.
- `lib/services/audio_share_service.dart` — platform share-sheet export of a recording (master preferred, session fallback) with temporary decryption of protected sources.
- `lib/services/wav_recovery_service.dart` — PCM16 WAV header repair for recordings interrupted by process death.
- `lib/services/recording_notification_service.dart` — Android method-channel bridge for the recording foreground service and its pause/stop notification actions.
- `android/app/src/main/kotlin/com/raven/raven/RecordingForegroundService.kt` — microphone-type foreground service keeping an active recording alive with a visible, actionable notification.
- `lib/services/ai_key_vault.dart` — OS secure-storage access for user-provided credentials.
- `lib/services/app_preferences.dart` — non-secret preferences (language, theme, quality options, app-lock toggle, public-by-default, trash retention and tour completion).
- `lib/services/app_lock_service.dart` — PIN verifier derivation and verification using secure storage; no plaintext PIN is persisted.
- `lib/services/attachment_service.dart` — sanitized attachment picking, project attachment listing and deletion.
- `lib/services/document_export_service.dart` — UTF-8-with-BOM encoding and safe `.txt` file naming for project notes.
- `lib/services/project_archive_service.dart` — safe ZIP bundle export/import with path-traversal guards, staged extraction and ID remapping, plus the streamed whole-library backup.
- `lib/services/audio_visibility_service.dart` — legacy single-file public-copy publishing to Android MediaStore or Windows Downloads (kept for cleanup of copies created by older builds; new visibility changes use the move-based `ProjectRepository.toggleVisibility`).
- `lib/services/audio_timeline.dart` — deterministic mapping between internal sessions and the single user-facing playback timeline.
- `lib/services/audio_merge_service.dart` — FFmpeg-backed, validated master-audio creation from retained source sessions (see *Master audio and FFmpeg*).
- `lib/services/background_encode_service.dart` — singleton background transcode queue (WAV capture → M4A/MP3/FLAC) with duplicate-job guards, stale-input detection, fresh-record rebasing before commit, a shared mutex for other file-rewriting services and `waitForProject()` used by the resume-merge and auto-publish paths.
- `lib/services/audio_trim_service.dart` — multi-region FFmpeg trimming that merges/clamps user regions, renders each kept segment with the source's codec tier and sample rate, joins segments with the concat demuxer, and serializes with background encodes through the shared mutex.
- `lib/services/audio_clean_service.dart` — FFT denoise render (high-pass + `afftdn`) written atomically under the encode mutex with progress reporting.
- `lib/services/waveform_service.dart` — FFmpeg `showwavespic` waveform images cached in the temp directory and in memory.
- `lib/widgets/trim_editor.dart` — full-screen trim editor: draggable timeline handles locked to the active gesture, cut-selection / keep-only composition, unlimited cuts anywhere in the recording, keep/cut visualization strip, selection playback preview with playhead, undo/reset, and an explicit save-choice dialog (replace original vs. save as a new take).
- `lib/services/ai_provider_service.dart` — opt-in REST integration for OpenRouter, OpenAI API, and Gemini API, with bounded prompts, timeouts, and provider error handling.
- `test/` — model, serialization, audio-timeline mapping, app-lock, encryption, password-dialog, PIN UX, archive-safety, responsive layout, AI-provider and WAV-recovery tests.

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
│       ├── attachments/      # imported files/images
│       ├── exports/          # project exports
│       └── metadata/         # project metadata/history
└── categories/
    └── <safe-category-name>/
        └── <project-uuid>.json  # lightweight pointer/manifest only
```

**Public project folders (Android):** when a project is made public, its entire folder is **physically moved** (not copied) to `/storage/emulated/0/Music/RAVEN/<name>-<short-uuid>/`. This requires `MANAGE_EXTERNAL_STORAGE` on Android 11+ (prompted lazily on first "Make public"). On Android 10 and below, `WRITE_EXTERNAL_STORAGE` + `requestLegacyExternalStorage` achieve the same without a runtime prompt. Making a project private moves the folder back to app-private storage. Resuming, adding notes, managing attachments, and deleting all work directly on the folder at its current location — no copies are involved.

**Windows / Linux public root:** `<Downloads>/RAVEN/<name>-<short-uuid>/`.

## App lock and private recordings

RAVEN stores recordings under the application-support directory by default. On Android, this is app-private storage and recordings normally do not appear in public music folders or a general file manager. This is different from encrypting a file: app-private storage limits ordinary access by other apps, while the app PIN gate prevents someone casually opening RAVEN on an already-unlocked device.

- Enable **Lock RAVEN with a PIN** in Settings and choose 4–12 digits. The PIN is not stored in plaintext; RAVEN stores a random salt and a PBKDF2-HMAC-SHA256 verifier (120 000 iterations) in platform secure storage.
- Individual projects can require that PIN before opening. Existing projects remain compatible because the field defaults to false when absent from older project JSON.
- The app lock is not a substitute for the phone/computer account lock, and it does not encrypt audio files against someone with filesystem/debug access or a compromised device.
- Turning off the app-wide lock keeps the verifier in secure storage so recordings individually locked with the PIN do not become inaccessible. If the PIN is forgotten, there is no automatic recovery flow yet; keep a backup of important recordings.
- Use a recording's three-dot menu and select **Lock audio with a password** to encrypt just that recording; this is separate from the app PIN. RAVEN requests a password and confirmation, derives an AES-256-GCM key using PBKDF2 (210 000 iterations), and does not store the password. The password cannot be reset: forgetting it makes the protected audio unrecoverable. Playback asks for the password and temporarily decrypts audio into app storage. Encryption currently buffers whole files in memory, so very large recordings may use substantial RAM; keep a separate backup and test with small files first.
- Encrypting a project deletes its unencrypted master file so no plain copy remains; decrypting attempts to rebuild it.

The Player screen includes a managed public-copy control for supported targets. “Show” creates a separate user-visible copy, while “Hide” removes the managed copy and leaves the private original in place. This is not encryption; users should not assume deleting a copy securely erases flash storage.

## Optional AI assistant

AI is opt-in and uses the user's own provider account. RAVEN does not include a shared API key or pay provider bills. Provider credentials are stored in `flutter_secure_storage`, not in `SharedPreferences`, project JSON, notes, logs, or project exports.

Supported providers in this build:

- **OpenRouter** — one OpenAI-compatible endpoint for a broad model catalogue. Create a key at https://openrouter.ai/keys, choose the exact model ID shown in its catalogue, and set a key spending limit. The default model is `meta-llama/llama-3.3-70b-instruct:free`; availability and free-tier limits are controlled by OpenRouter, and many other models require credits.
- **OpenAI API** — create a key at https://platform.openai.com/api-keys. A ChatGPT subscription is separate from API billing; check usage and billing before using it.
- **Google Gemini API** — create/manage a key at https://aistudio.google.com/app/apikey and check project quotas and billing. The default model is `gemini-2.0-flash`; model names are editable and should be checked against Google's current model catalogue: https://ai.google.dev/gemini-api/docs/models.

Settings lets the user choose the provider, enter a model identifier, save the key, test the connection, and delete a saved key. The test makes a real small API request, so provider usage policies and possible charges apply. Model names, availability, limits, and prices change; treat the model field as editable rather than promising that one default stays valid forever.

Portable ZIP export/import currently assembles archive contents in memory; very large projects may use substantial RAM, especially on phones. (The whole-library backup streams instead.) Encrypted projects cannot be exported portably until a user-controlled backup/key migration design exists.

The project notes screen offers **Summarize**, **Organize and polish**, and **Translate** actions. Before each request, RAVEN asks permission and explains which provider receives the notes. These actions send text from the notes field only; they do not upload the recording audio. Results are shown for review and are not saved over the notes unless the user chooses Replace notes. AI remains optional and core recording works without a key. The current provider client supports text requests, not audio transcription or sending attachments.

Provider requests use HTTPS, a 45-second timeout, a 60,000-character prompt limit, and no automatic retries. The app does not intentionally log API keys or prompts. Direct API calls from a user device still mean the selected provider receives submitted text; users should avoid sending confidential content unless they accept that provider's terms. For production release, test key-redaction and provider-specific error handling with mocked responses as well as real provider accounts.

## Settings explained for everyday users

| Setting | Choices | What it does |
|---|---|---|
| Dark appearance | On / Off | Low-glare dark or bright light theme |
| Interface language | English / Français | UI, dialogs, snackbars and the tour |
| Backup all recordings | Action | Streams the library to one ZIP and opens the share sheet |
| Trash retention | 7 / 14 / 30 / 60 / 90 days / Never | How long deleted items stay recoverable; **Never** keeps them until deleted manually |
| Sample rate (kHz) | 16 / 22.05 / 44.1 / 48 | More samples capture more high-frequency detail; 44.1/48 kHz are safe general-purpose choices |
| Bitrate (kbps) | 64 / 96 / 128 / 192 / 256 | Compressed audio only; higher usually means larger files and better quality. WAV/FLAC ignore it on most platforms |
| Recording format | M4A / MP3 / WAV / FLAC | M4A/AAC is compact; MP3 is widely compatible; WAV is uncompressed and large; FLAC is lossless where supported |
| Voice enhancement | On / Off | Asks the device recorder for automatic gain, echo cancellation and noise suppression; results vary |
| AI provider key | Action | Open the key/model editor for OpenRouter, OpenAI or Gemini |
| Private app storage | Info | Reminds users where recordings live by default |
| Audio encryption | Info | Explains the per-recording password lock and that it is separate from the PIN |
| Public audio by default | On / Off | New recordings are moved into `Music/RAVEN` (no duplicate) |
| Make all recordings public / private | Actions | Bulk **move** of every unencrypted recording |
| Lock RAVEN with a PIN | On / Off | PIN gate when the app starts after being closed |
| Replay the guided tour | Action | Re-opens the walkthrough of recording, library, settings and privacy |

## Continue recording and automatic master merge

Open an existing project and tap the microphone action. RAVEN appends a new internal source session to the same stable project ID and title. After Stop, it first saves the source session to the project index, then (where FFmpeg support is available) creates a single continuous master file. The merge re-encodes to the project's current output format (AAC/M4A, MP3 via `libmp3lame`, PCM/WAV, or FLAC) so sessions with different recording settings can be normalized. A pending file is validated before being renamed into place. Original session files are retained as recovery sources; they are not deleted after a successful merge. Playback prefers the master file and falls back to the continuous session playlist if the master is missing or merge fails. The global seek bar and bookmarks remain tied to the combined timeline. The master is removed when project audio is encrypted so it cannot remain as an unencrypted copy; after decryption, RAVEN attempts to rebuild it.

### Master audio and FFmpeg (Android APK size)

`ffmpeg_kit_flutter_new_audio` is bundled on every platform in the current pubspec because trimming, cleaning, amplifying and resume-merge all depend on FFmpeg. That costs roughly 20–30 MB of native libraries in the Android APK. Configuration notes:

- FFmpeg is **not** excluded from Android today; an earlier build excluded the AAR and skipped merging. If you need a smaller APK and can accept session-playlist playback instead of a merged master, exclude the module in `android/app/build.gradle.kts` and gate merging with `AudioMergeService.isSupported`.
- `android/app/build.gradle.kts` limits ABIs to `arm64-v8a` and `armeabi-v7a`, enables R8 minification and resource shrinking for release builds, and strips duplicate `META-INF` license/notice files.
- The FFmpeg audio package is LGPL-3.0. Follow its redistribution terms and ship the `licenses/ffmpeg_kit_flutter_new_audio/` notices generated beside the Windows executable when distributing a Windows build. Check the package's current platform matrix and license bundle before each release.

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
- **FFmpeg:** bundled (see *Master audio and FFmpeg*).
- **Version warnings:** Flutter warns that older Gradle, AGP and Kotlin versions will soon be unsupported. Build with `--android-skip-build-dependency-validation` until you upgrade them.
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
16. **Trim handle behaviour:** drag the start handle past the end handle's position and back — the handle you grabbed must keep moving (no mid-drag flip), and the selection must never collapse to zero length. Tap near each handle and confirm the nearest one jumps to the tap point.
17. **No duplicate storage:** make a standalone recording public, then check the device with a file manager — exactly one copy of the audio must exist (inside `Music/RAVEN/<name>-<id>/sessions/`), and the app-private folder must be gone. Make it private again and confirm the reverse. Repeat for a multi-take project, and again after resuming a public recording (the merge must not create a second public copy). Compare total device storage before and after to confirm it stays flat.
18. **Settings switches:** toggle *Public audio by default*, *Lock RAVEN with a PIN* and *Voice enhancement*; close and reopen the app and confirm each switch keeps its state. With *Public audio by default* on, record a new take and confirm it lands in the public RAVEN folder without a duplicate.
19. **Clean audio:** record with a fan or hum in the room, run *Clean audio*, confirm the progress indicator advances, playback uses the cleaned file, the original is gone, and the file keeps its format. Repeat on a WAV and on an MP3 take. Confirm the action is unavailable on an encrypted project and that a queued background encode finishes before the clean starts.
20. **Amplify:** open the Amplify sheet, drag to 2.0× and confirm the preview is louder without clipping; press play to confirm playback still works; save to the take and relaunch the app to confirm the amplified file persisted. Set the slider back to 1.0× and confirm the original audio returns and the temporary boosted file is removed.
21. **Backup:** run *Backup all recordings* on a library with several GB; confirm the app stays responsive (the archive is streamed), the ZIP opens on a computer containing `projects.json` and the project folders, and temp files (`*.tmp`, `*.pending`, `*.bak`) are absent.
22. **Trash retention:** set retention to 7 days, trash an item with a backdated `trashedAt`, relaunch, and confirm it is purged. Set *Never* and confirm nothing is purged.

## Contributing

Contributions are welcome under the terms of the GPL-3.0 license.

1. Run `flutter pub get`, `flutter analyze` and `flutter test` before opening a change.
2. Keep persistence inside `ProjectRepository` — do not write project JSON or invent file paths from screens.
3. Keep audio byte content stable: edits must render to a temporary file and be validated before being renamed into place, and must take the `BackgroundEncodeService` mutex.
4. Never persist PINs, passwords or API keys in plaintext, project JSON, notes, logs or exports.
5. Provide English and French strings (`tr(preferences, 'English', 'Français')`) for every user-facing string.
6. By submitting a contribution you agree to license it under GPL-3.0. Do not copy code from sources under incompatible terms.

## License

RAVEN — Record · Archive · Visualise · Edit · Notes
Copyright (C) 2026 MbunaKellyGlennA. (KellyGlennIT)

RAVEN is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version**. The full text is in [LICENSE](LICENSE).

RAVEN is distributed in the hope that it will be useful, but **WITHOUT ANY WARRANTY**; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details: https://www.gnu.org/licenses/gpl-3.0.html

What this means in practice:

- You may use RAVEN for any purpose, study the source, modify it and share your modified versions.
- If you distribute RAVEN or a modified version — as source, as a built app, or on an app store — you must pass on the same freedoms and make the **complete corresponding source code** available under GPL-3.0, and keep the copyright and license notices intact.
- A network service built from RAVEN does not have to publish its source (that would require AGPL-3.0); but any distributed binary or app package must.
- Modifying the app on a device you own is permitted; distributing a locked-down version that prevents recipients from running modified versions is not.
- Older releases published under the MIT License remain available under those MIT terms; the change applies to this version and later ones.

Bundled third-party packages keep their own licenses (the FFmpeg audio package is LGPL-3.0, compatible with the GPL). The upstream Fossify Voice Recorder archive in `reference/` is GPL-3.0 and is kept for auditing only — see [NOTICE.md](NOTICE.md).

## Scope still to finish

This codebase does not yet constitute the entire planned RAVEN product. Remaining larger features include backup hardening, transcription and AI processing of audio (the provider client currently sends text only), streaming-safe encryption (encryption currently buffers whole files in memory), and end-to-end recovery verification on every platform. Interrupted-recording draft recovery is wired end to end but still needs device verification across Android versions and storage conditions. Portable project export/import is wired into the Player/Library UI but requires round-trip testing with real archives, imported audio and large attachments. Trimming is region-based (keep/cut spans); waveform-accurate scrubbing, crossfades at cut points, per-region gain and silence detection are not implemented yet. Noise cleaning uses one fixed FFmpeg profile with no user-adjustable strength, and amplification caps at 3.0×.
