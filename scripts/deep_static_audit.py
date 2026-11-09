"""Dependency-free RAVEN source sanity checks; not a Dart/Kotlin compiler.

Run: python scripts/deep_static_audit.py
This checks local imports, YAML/XML structure, delimiter balance outside strings/comments,
and a few high-risk source invariants. It cannot type-check plugins or execute Flutter.
"""
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET
import yaml

ROOT = Path(__file__).resolve().parents[1]
errors: list[str] = []
checks: list[str] = []


def lexical_delimiter_errors(source: str, label: str) -> list[str]:
    pairs = {')': '(', ']': '[', '}': '{'}
    opens = set(pairs.values())
    problems: list[str] = []

    def skip_block_comment(i: int) -> int:
        depth = 1
        i += 2
        while i < len(source) and depth:
            if source.startswith('/*', i):
                depth += 1
                i += 2
            elif source.startswith('*/', i):
                depth -= 1
                i += 2
            else:
                i += 1
        if depth:
            problems.append(f'{label}: unterminated block comment')
        return i

    def skip_string(i: int) -> int:
        quote = source[i]
        triple = source.startswith(quote * 3, i)
        delimiter = quote * (3 if triple else 1)
        # Dart/Kotlin raw string prefix. For delimiters, raw strings do not use backslash escapes.
        raw = i > 0 and source[i - 1] in 'rR' and (i == 1 or not (source[i - 2].isalnum() or source[i - 2] == '_'))
        i += len(delimiter)
        while i < len(source):
            if source.startswith(delimiter, i):
                return i + len(delimiter)
            if not raw and source[i] == '\\':
                i += 2
                continue
            if source.startswith('${', i):
                # Validate expression delimiters inside interpolation independently.
                end, inner_errors = scan_code(i + 2, stop_at_interp_close=True)
                problems.extend(inner_errors)
                if end <= i + 2 or end > len(source) or source[end - 1] != '}':
                    problems.append(f'{label}: unterminated string interpolation near offset {i}')
                    return len(source)
                i = end
                continue
            i += 1
        problems.append(f'{label}: unterminated string literal')
        return len(source)

    def scan_code(i: int, stop_at_interp_close: bool = False) -> tuple[int, list[str]]:
        stack: list[tuple[str, int]] = []
        local_problems: list[str] = []
        while i < len(source):
            if source.startswith('//', i):
                end = source.find('\n', i + 2)
                i = len(source) if end < 0 else end + 1
                continue
            if source.startswith('/*', i):
                i = skip_block_comment(i)
                continue
            ch = source[i]
            if ch in '\"\'':
                i = skip_string(i)
                continue
            if stop_at_interp_close and ch == '}' and not stack:
                return i + 1, local_problems
            if ch in opens:
                stack.append((ch, i))
            elif ch in pairs:
                if not stack:
                    local_problems.append(f'{label}: unexpected {ch!r} at offset {i}')
                elif stack[-1][0] != pairs[ch]:
                    local_problems.append(
                        f'{label}: mismatched {ch!r} at offset {i}; expected closing delimiter for {stack[-1][0]!r} from offset {stack[-1][1]}'
                    )
                    stack.pop()
                else:
                    stack.pop()
            i += 1
        if stop_at_interp_close:
            local_problems.append(f'{label}: unclosed string interpolation')
        for opener, offset in stack:
            local_problems.append(f'{label}: unclosed {opener!r} delimiter at offset {offset}')
        return i, local_problems

    _, code_problems = scan_code(0)
    problems.extend(code_problems)
    return problems

# Parse dependency manifest and verify expected foundation.
pubspec_path = ROOT / 'pubspec.yaml'
try:
    pubspec = yaml.safe_load(pubspec_path.read_text(encoding='utf-8'))
    if pubspec.get('name') != 'raven':
        errors.append('pubspec.yaml: package name is not raven')
    if pubspec.get('environment', {}).get('flutter') != '>=3.47.5':
        errors.append('pubspec.yaml: expected Flutter >=3.47.5')
    deps = pubspec.get('dependencies', {})
    for dep in ['record', 'just_audio', 'ffmpeg_kit_flutter_new_audio', 'flutter_secure_storage', 'path', 'file_picker']:
        if dep not in deps:
            errors.append(f'pubspec.yaml: required dependency {dep} is missing')
    checks.append('pubspec YAML parsed; package/environment/dependency foundations checked')
except Exception as exc:
    errors.append(f'pubspec.yaml could not be parsed: {exc}')


# Ensure every external package URI is declared directly (excluding this app's
# own package name), to catch accidental reliance on transitive dependencies.
try:
    declared = set(pubspec.get('dependencies', {})) | set(pubspec.get('dev_dependencies', {}))
    used: set[str] = set()
    for path in list((ROOT / 'lib').rglob('*.dart')) + list((ROOT / 'test').rglob('*.dart')):
        used.update(re.findall(r"(?:import|export|part)\s+'package:([^/]+)/", path.read_text(encoding='utf-8')))
    undeclared = used - declared - {pubspec.get('name')}
    if undeclared:
        errors.append(f'package imports missing direct pubspec dependencies: {sorted(undeclared)}')
    else:
        checks.append('package import declarations checked against pubspec dependencies')
except Exception as exc:
    errors.append(f'package import declaration check failed: {exc}')

# Validate relative imports and delimiter balance across Dart/Kotlin sources.
source_files = list((ROOT / 'lib').rglob('*.dart')) + list((ROOT / 'test').rglob('*.dart'))
source_files += list((ROOT / 'android/app/src/main/kotlin').rglob('*.kt'))
for path in source_files:
    rel = path.relative_to(ROOT).as_posix()
    content = path.read_text(encoding='utf-8')
    errors.extend(lexical_delimiter_errors(content, rel))
    if path.suffix == '.dart':
        import_start = 0
        for line_no, line in enumerate(content.splitlines(), 1):
            # Check literal relative imports; package imports need the resolved pub package graph.
            if line.lstrip().startswith(('import ', 'export ', 'part ')):
                import_start = line_no
                import_line = line.strip()
                if "'../" in import_line or "'./" in import_line or '"../' in import_line or '"./' in import_line:
                    import_value = import_line.split('from ')[-1].strip().rstrip(';').strip('"\'') if ' from ' in import_line else import_line.split()[1].strip().rstrip(';').strip('"\'')
                    if import_value.startswith(('../', './')):
                        target = (path.parent / import_value).resolve()
                        if not target.is_file():
                            errors.append(f'{rel}:{line_no}: relative import target missing: {import_value}')
checks.append(f'lexical delimiter checks completed for {len(source_files)} Dart/Kotlin files')

# Android manifest well-formedness and permissions/components required by source bridge.
manifest_path = ROOT / 'android/app/src/main/AndroidManifest.xml'
try:
    manifest_tree = ET.parse(manifest_path)
    root = manifest_tree.getroot()
    android_ns = '{http://schemas.android.com/apk/res/android}'
    permissions = {node.get(android_ns + 'name') for node in root.findall('uses-permission')}
    for permission in ['android.permission.INTERNET', 'android.permission.RECORD_AUDIO', 'android.permission.POST_NOTIFICATIONS']:
        if permission not in permissions:
            errors.append(f'AndroidManifest.xml missing permission {permission}')
    app_text = manifest_path.read_text(encoding='utf-8')
    for component in ['.MainActivity', '.RecordingForegroundService']:
        if component not in app_text:
            errors.append(f'AndroidManifest.xml missing component {component}')
    if 'SCHEDULE_EXACT_ALARM' in app_text or 'ScheduledRecordingReceiver' in app_text:
        errors.append('AndroidManifest.xml still configures scheduled recording')
    checks.append('Android manifest parsed; recording permissions and components checked')
except Exception as exc:
    errors.append(f'AndroidManifest.xml could not be parsed: {exc}')

# High-risk regression/invariant checks.
required = [
    'lib/main.dart', 'lib/models/raven_project.dart', 'lib/services/project_repository.dart',
    'lib/services/audio_merge_service.dart', 'lib/services/audio_timeline.dart',
    'lib/services/ai_provider_service.dart', 'lib/services/ai_key_vault.dart',
    'lib/services/app_lock_service.dart',
    'lib/services/audio_visibility_service.dart', 'lib/screens/recorder_screen.dart',
    'lib/screens/player_screen.dart', 'lib/screens/library_screen.dart',
    'lib/screens/settings_screen.dart',
    'test/raven_project_test.dart', 'test/audio_timeline_test.dart',
    'test/ai_provider_service_test.dart', 'test/project_archive_safety_test.dart', 'README.md', 'BUILD_STATUS.md',
]
for relative in required:
    if not (ROOT / relative).is_file():
        errors.append(f'missing required project file: {relative}')

checks_for_text = {
    'stable project identity/model': ('lib/models/raven_project.dart', 'RavenProject copyWith'),
    'AI request timeout': ('lib/services/ai_provider_service.dart', 'Duration(seconds: 45)'),
    'AI redirects disabled': ('lib/services/ai_provider_service.dart', 'request.followRedirects = false'),
    'atomic master pending output': ('lib/services/audio_merge_service.dart', '.master.pending.'),
    'master rollback backup': ('lib/services/audio_merge_service.dart', '.previous'),
    'rename regression test': ('test/raven_project_test.dart', 'renaming never changes audio paths'),
    'corrupt-master playback fallback': ('lib/screens/player_screen.dart', 'Prefer the fast master file, but a present file can still be truncated'),
    'protected-audio cleanup warning': ('lib/screens/player_screen.dart', 'could not remove every old plaintext file'),
    'portable import installer': ('lib/services/project_archive_service.dart', 'Future<RavenProject> installStagedImport'),
    'Library import workflow': ('lib/main.dart', 'installStagedImport(staged)'),
    'current Gemini stable default': ('lib/services/ai_provider_service.dart', 'gemini-3.8-flash'),
    'ZIP import rejects original parent-directory segments': ('lib/services/project_archive_service.dart', "segment == '..'"),
    'archive traversal regression tests': ('test/project_archive_safety_test.dart', 'rejects traversal before normalization can hide it'),
}
for label, (relative, needle) in checks_for_text.items():
    text = (ROOT / relative).read_text(encoding='utf-8')
    if needle not in text:
        errors.append(f'missing expected invariant ({label}) in {relative}')
checks.append('required feature files and selected recovery/privacy/AI/rename invariants checked')

if errors:
    print('RAVEN DEEP STATIC AUDIT: FAILED')
    for item in errors:
        print(f' - {item}')
    sys.exit(1)
print('RAVEN DEEP STATIC AUDIT: PASSED')
for item in checks:
    print(f' - {item}')
print('LIMITATION: this is lexical/structural validation, not the Dart analyzer, Flutter tests, Gradle build, or device testing.')
