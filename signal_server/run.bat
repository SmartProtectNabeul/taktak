@echo off
setlocal
cd /d "%~dp0"

rem Signaling relay only uses embedded dart.exe below. Flutter app/widget tests need `flutter test`
rem (often with Git on PATH for the Flutter tool, and Windows Developer Mode enabled for symlink support).

rem Optimal on Windows without git on PATH: use Flutter's real dart.exe (not flutter\bin\dart.bat).
set "SDK=%USERPROFILE%\Documents\flutter\bin\cache\dart-sdk\bin\dart.exe"
if defined DART_EXE set "SDK=%DART_EXE%"
if defined FLUTTER_ROOT set "SDK=%FLUTTER_ROOT%\bin\cache\dart-sdk\bin\dart.exe"

if not exist "%SDK%" (
  echo [taktak] Dart not found at: "%SDK%"
  echo Set DART_EXE=full\path\to\dart.exe   or   FLUTTER_ROOT=...\flutter   then retry.
  pause
  exit /b 1
)

"%SDK%" pub get || exit /b 1
"%SDK%" run bin/taktak_signal.dart %*
