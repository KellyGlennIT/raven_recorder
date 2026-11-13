# Open-source notice

RAVEN — Record · Archive · Visualise · Edit · Notes
Copyright (C) 2026 MbunaKellyGlennA. (KellyGlennIT)

RAVEN is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License, version 3 or (at your option) any later version**, as published by the Free Software Foundation. The full license text is in `LICENSE`. RAVEN is distributed **WITHOUT ANY WARRANTY**, without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

If you distribute RAVEN or a modified version — as source, as an app package, or on a store — you must provide the complete corresponding source code under the same license and keep these notices intact. See https://www.gnu.org/licenses/gpl-3.0.html for the full terms.

## Upstream reference

The conversion was requested from the provided Fossify Voice Recorder source archive. The original Kotlin project is retained in `reference/fossify_voice_recorder_original.zip` for auditing and feature comparison. That upstream project declares GNU GPL v3.0; its license text is kept unmodified at `reference/GPL-3.0-LICENSE.txt`.

The Flutter code in this repository was newly written for RAVEN and does not include or link the upstream Kotlin sources. The archive is kept only as a reference and is not part of the built application. Because RAVEN is now itself licensed under GPL-3.0, the two licenses are compatible if you choose to port code from the archive.

## Third-party components

Bundled dependencies keep their own licenses (for example, the FFmpeg audio package is LGPL-3.0, which is compatible with the GPL when the LGPL linking conditions are met). Preserve their notices when redistributing builds.

## License history

Earlier releases of RAVEN were published under the MIT License. Those releases remain available under the MIT terms; this repository and all later releases are distributed under GPL-3.0.
