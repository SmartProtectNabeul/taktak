# Run signaling without invoking Flutter's `dart.bat` shim (which requires git on PATH).
param([int]$Port = 8787)

$dart = @(
    if ($env:DART_EXE) { $env:DART_EXE }
    if ($env:FLUTTER_ROOT) { Join-Path $env:FLUTTER_ROOT "bin\cache\dart-sdk\bin\dart.exe" }
    Join-Path $env:USERPROFILE "Documents\flutter\bin\cache\dart-sdk\bin\dart.exe"
    Join-Path $env:USERPROFILE "flutter\bin\cache\dart-sdk\bin\dart.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if (-not $dart) {
    Write-Error @"
Dart SDK not found. Install/use one of:

  • Add Git to PATH and use Flutter's shim: dart run bin/taktak_signal.dart
  • Set FLUTTER_ROOT to your Flutter folder, then re-run .\run_signal.ps1
  • Install Dart: https://dart.dev/get-dart
"@
    exit 1
}

Set-Location $PSScriptRoot
& $dart pub get
& $dart run bin/taktak_signal.dart $Port
