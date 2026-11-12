# Open-source notice

RAVEN is released under the MIT License. See `LICENSE`.

## Upstream reference

The conversion was requested from the provided Fossify Voice Recorder source archive. The original Kotlin project is retained in `reference/fossify_voice_recorder_original.zip` for auditing and feature comparison. That upstream project declares GNU GPL v3.0; its license text is kept unmodified at `reference/GPL-3.0-LICENSE.txt`.

The Flutter code in this repository was newly written for RAVEN and does not include or link the upstream Kotlin sources. The archive is kept only as a reference and is not part of the built application. If you later copy code from that archive into RAVEN, the copied material stays under GPL-3.0 and the MIT license above cannot override it — review the GPL-3.0 obligations before doing so.

## Third-party components

Bundled dependencies keep their own licenses (for example, the FFmpeg audio package is LGPL-3.0). Preserve their notices when redistributing builds.
