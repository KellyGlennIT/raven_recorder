# RAVEN developer integration guide

## Development rules

1. Keep UI widgets in `lib/screens/`, domain data in `lib/models/`, and filesystem/crypto/plugin work in `lib/services/`.
2. Use `RavenProject.id` as the stable identity. Never derive identity from a mutable title/category.
3. `ProjectRepository` owns the canonical `projects.json` index. Do not write the index from a screen.
4. Audio session paths point to the actual file. When encryption changes the path, persist the new path before removing the old file.
5. Do not put API keys, passwords, encryption keys, or private audio content in `SharedPreferences`, project JSON, logs, analytics, or PDFs.
6. AI-generated material belongs in a separate model field and must never silently replace original notes/audio.
7. All new UI copy must be available in English and French. Settings should explain the effect and trade-off of a technical parameter in plain language.
8. Platform capabilities differ. Check microphone, codec, secure storage, PDF printing and desktop behavior on real target platforms.

## Adding a new project attachment

- Create/use `projects/<stable-project-id>/attachments/`.
- Give the attachment its own UUID and preserve original filename/type metadata.
- Update a serializable attachment model and the project manifest/index through the repository.
- Do not create empty attachment files. Handle missing/deleted files gracefully.
- Include attachments in the eventual export/import format, but never include device encryption keys or AI credentials.

## Adding a new category

- Store the category as project metadata.
- Let `ProjectRepository` update the lightweight manifest under `categories/<safe-category-name>/`.
- Never move the canonical project directory or rewrite audio paths when changing category.
- Deleting a category should first reassign its projects to `Uncategorized` or a category chosen by the user. It must not delete project audio.

## Extending encryption

`AudioEncryptionService` currently uses AES-256-GCM and a random key in OS secure storage. Protected files are tagged with a RAVEN-specific header and authenticated during decryption. The Player screen offers a lock icon that encrypts/decrypts all sessions and decrypts into temporary playback files.

Before release, add automated service-level round-trip/tamper tests, chunked encryption for very large recordings, app lifecycle cleanup of temporary plaintext, a documented key-loss/recovery policy, and user-defined password/portable key derivation if cross-device protected export is required. Device-key encryption and a user password are not interchangeable. Never claim encrypted audio can be recovered if its device key is gone.

## Local verification on Windows

Run from the root folder in PowerShell:

```powershell
flutter --version
flutter doctor -v
flutter create --platforms=windows .
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

Then test on a physical Android phone. Resolve every analyzer error, review warnings, and test failure/recovery paths rather than suppressing diagnostics. This source archive was prepared without Flutter/Dart installed in the build environment, so no successful analyzer/test/build result is claimed.
