# RAVEN build status — scheduled recording review

## Changes in this review build

- Audited project renaming in the Library and Player screens. The project UUID remains the storage identity; title changes do not move the project directory or change session/master paths. Added a regression test covering those invariants.
- Added one-off scheduled recording UI under **Settings → Scheduled recordings**. A schedule has a date, time and optional project title; users can review or cancel upcoming schedules.
- While RAVEN is foregrounded and unlocked at the scheduled time, its recorder screen opens and begins recording with the saved title.
- On Android, exact alarms produce a **silent but visible notification**. Tapping it opens RAVEN and starts the recording if the scheduled time is no more than 15 minutes past. Notification text does not expose the chosen recording title on the lock screen.
- Added Android notification permission and exact-alarm access handling, receiver plumbing, cancellation and best-effort restoration after device reboot/app replacement.
- The alarm receiver never opens the microphone by itself. Android restricts microphone foreground-service starts from the background; therefore, this build does not secretly start recording while RAVEN is closed. When the app is not active, the user must tap the visible notification. On Windows and other non-Android targets, RAVEN must remain open for the schedule to trigger.
- Updated README and architecture review with the implemented behavior and platform limits.

## Checks completed in this environment

- `python scripts/static_project_check.py` — passed. Checks required files and local relative Dart imports only.
- Android manifest XML parse — passed.
- Basic Kotlin source delimiter-balance check — passed.
- ZIP integrity check — run on the produced archive.

## Checks not run

Flutter and Dart executables are not installed in this environment. Consequently, **`flutter pub get`, `flutter analyze`, `flutter test`, Kotlin/Gradle compilation, APK creation and real-device testing have not been run**. This ZIP is a reviewed source build, not a verified APK/release. On the development PC, run `scripts/verify_windows.bat`; it generates a Windows runner if missing, then runs dependency resolution, analysis, tests, APK build and Windows desktop build. Windows desktop compilation also requires Visual Studio with the Desktop development with C++ workload. Then test schedule start, notification tap, permission denial, device reboot, force-stop, calls and microphone access on a physical Android device.

## Additional correctness fixes in the current audit pass

- Added Android INTERNET permission for the optional user-keyed AI HTTP calls.
- Normalized persisted recording sample rate, bitrate and format values so malformed/old preferences cannot feed unsupported values into dropdowns or the recorder.
- AI requests now refuse redirects (to avoid forwarding API credentials to an unexpected destination), handle non-JSON provider errors more clearly, and parse text-part arrays returned by compatible chat APIs.
- AI setting saves/test successes refresh the Settings view so its provider/model label updates immediately.
- Master-audio replacement now keeps a rollback copy until the new master is committed.
- Recovered multi-session drafts now measure the final session independently (instead of accidentally reusing the first playlist item's duration) and attempt to rebuild a master while preserving segment playback as fallback. Notes-save errors are shown to the user.
- Portable export now refuses encrypted projects whose key is device-local, instead of creating an archive that cannot be decrypted on another device; session paths in manifests are relative. The complete import/install UI was added in the latest audit pass below.


## Latest audit pass — additional fixes

- Player loading now falls back to the retained session playlist when a referenced master is missing or fails to load, rather than treating a corrupt master as the only playback path.
- Audio protection now validates replacement playback before deleting original source files; failures retain the originals for recovery. It retries removal of leftover plaintext source/master copies after switching playback and presents an in-player warning if plaintext cleanup cannot be confirmed.
- Added a complete project-bundle install path and Library import action. Imports validate relative session paths, copy the staged project into private storage, map audio paths to the new directory, and generate a new stable project ID. Device-specific public-copy paths, encryption state and per-project PIN requirement are not carried into a portable import.
- Bundle export omits reproducible master/rollback files; direct `path` dependency is declared explicitly.
- Static source checks were rerun after these changes; see `RAVEN_AUDIT_REPORT.md` for exact results and verification limits.

- Hardened portable-import ZIP path validation: checks original path segments (before normalization) to reject `..` traversal, absolute paths, drive-qualified paths, empty path segments, and NULs. Added regression tests for ordinary paths, directory entries, traversal and absolute paths.
- Portable export also refuses session paths ending in `.ravenenc`, even if stale project metadata incorrectly says protection is off.
