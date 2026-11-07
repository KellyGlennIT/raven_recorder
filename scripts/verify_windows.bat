@echo off
setlocal
cd /d "%~dp0\.."
where flutter >nul 2>nul
if errorlevel 1 (
  echo Flutter was not found on PATH. Install Flutter and reopen the terminal.
  exit /b 1
)
flutter --version || exit /b 1

REM The source baseline has Android files but may not yet have a generated Windows runner.
if not exist "windows\CMakeLists.txt" (
  echo Generating the Flutter Windows desktop runner...
  flutter create --platforms=windows . || exit /b 1
)

flutter pub get || exit /b 1
flutter analyze || exit /b 1
flutter test || exit /b 1
flutter build apk --debug || exit /b 1
flutter build windows --debug || exit /b 1

echo Dependency resolution, analysis, tests, Android debug APK and Windows desktop build completed.
