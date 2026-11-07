# Migration audit: supplied Kotlin recorder → Flutter RAVEN baseline

This audit is deliberately specific: “present in the UI” does not mean a feature is fully migrated or release-ready.

## Rebuilt in Flutter baseline

| Source capability / RAVEN core | Status | Current implementation |
|---|---|---|
| Recording screen and live duration | Implemented in Dart | `record` plugin; stopwatch-driven timer |
| Start / pause / resume / stop | Implemented in Dart | New capture route auto-starts once microphone permission is granted |
| Cancel active recording | Implemented in Dart | Confirmation dialog, then deletes the unfinished project folder |
| Audio level visualisation | Basic implementation | Live amplitude from the recording plugin; visual bars only, not a saved waveform editor |
| M4A/AAC recording | Implemented | Default encoder |
| WAV / FLAC recording options | Implemented through plugin | Must be device-tested; support can vary by target/platform |
| Sample rate / bitrate settings | Implemented | Saved locally; actual device encoder may clamp unsupported values |
| Auto gain / echo cancellation / noise suppression | Partial | Requests the platform/plugin effects when available; not a full DSP chain and availability is device-dependent |
| Recording becomes project automatically | Implemented | No pre-recording project setup; stable ID and private project folder are created automatically |
| Project rename | Implemented | Title changes without changing the project ID or audio path |
| Record library / search | Basic implementation | Searches title, category and tags; category/tag editing UI is not yet implemented |
| Favourite marking | Implemented | Saved in project metadata |
| Trash / restore / delete forever | Implemented | Trash retains the project; permanent delete removes its project folder |
| Playback / seeking / speed | Implemented | Uses `just_audio` |
| Project notes | Basic implementation | Plain-text note stored separately from audio; timestamp linking not yet implemented |
| Dark/light mode | Implemented | Saved preference |
| English/French labels | Partial implementation | Major capture, library and settings flows have both languages; not every system message or date format has had native-device review |
| Adaptive navigation | Implemented in UI | Bottom navigation on narrow screens; NavigationRail on wide layouts |
| Private app directory | Implemented | Defaults to app support storage; not encrypted |
| Model ready for multiple audio sessions | Implemented in data model | Current UI can select among sessions if there are multiple; adding sessions to an existing project is not exposed yet |

## Not yet migrated / not release-ready

| Original / planned feature | Why it remains pending |
|---|---|
| MP3 encoder | The selected Flutter recorder plugin does not expose an MP3 encoder. Port the existing LAME encoder behind a maintained platform interface or add a vetted compatible encoder and verify licensing. |
| OGG/Opus feature parity | The plugin's Opus container and platform limits differ from the source implementation; must verify Android 10+ and extension/player compatibility before exposing it as a promised option. |
| Android microphone source modes (camcorder, unprocessed, voice communication, performance, recognition) | Needs mapping to plugin Android configuration and tests on physical devices. |
| Custom filename patterns/date-time pattern editor | Not ported yet; current titles use date/time automatically and can be renamed afterwards. |
| User-selected external recording folder / folder permission workflow | Current default is safer app-private storage; folder picker and migration flow remain pending. |
| Move recordings between folders/categories | Category management is not implemented in this baseline; do not use file moves to model category changes. |
| Android quick-record home-screen widget | Requires a native Android App Widget and channel integration. |
| Persistent recording notification / robust background recording | Requires the plugin's documented background-recording setup and physical-device testing with screen lock, app switching and OEM battery controls. Manifest permissions alone do not complete this feature. |
| Android system `RECORD_SOUND` intent integration | Not registered in this scaffold yet. |
| Full trash management (empty trash / bulk selection / undo) | Basic single-project trash and restore only. |
| Audio import/export/share and complete project archive | Not implemented; secure handling and format validation need separate work. |
| Audio trimming, waveform editing, advanced filters and audio effects | Not implemented; voice enhancement requests are not equivalent to the source app's full modes or a studio DSP chain. |
| Password/PIN/biometric app lock and password-gated audio | Not implemented. No security claim should be made based on private app storage alone. |
| Encryption at rest and protected export | Not implemented; must use vetted authenticated encryption, key derivation/wrapping, and avoid persistent plaintext copies. |
| PDF/document attachments, timestamped notes, bookmarks, transcripts and AI BYO-key integration | These are RAVEN workspace features that belong to the next integration stage. |
| Existing Kotlin widget, foreground service, notification, and theme customization parity | Original Kotlin source is kept in `reference/`, but these systems have not been translated into Flutter/native bridge implementations. |

## Test status

- Source tree and package configuration were manually reviewed.
- Android manifest and resource XML are checked for well-formedness in the preparation environment.
- A model serialization unit test is included under `test/`.
- `flutter analyze`, `flutter test`, dependency resolution and APK build have **not** been run because Flutter/Dart were not installed in this environment and the package registry was unreachable. Run the commands in `README.md` on the development PC and fix any findings before integrating or distributing the app.


## RAVEN integration pass (2026-10-28)

- Added backwards-compatible `RavenBookmark` serialization and project fields for audio-protection state and separately stored AI-generated content. Existing project JSON loads with safe defaults.
- Added `AiKeyVault`, which stores user-entered provider keys using OS secure storage and validates provider identifiers. AI calls themselves are intentionally not made without an explicit feature/provider integration.
- Added `AudioEncryptionService` using authenticated AES-256-GCM and an OS-secured key. This is a cryptographic building block, not an end-to-end protected-playback feature yet; do not mark user audio as protected until recording, playback, exports and recovery are integrated.
- Added notes PDF generation and a print/share action from the project player.
- Updated setup instructions for Flutter 3.47.5 and Windows desktop scaffolding.
- Validation limitation: this build container has Java but no `flutter` or `dart` executable and cannot honestly report `flutter analyze`, `flutter test`, APK or Windows build success. Run all four checks on the target PC after dependency resolution.
