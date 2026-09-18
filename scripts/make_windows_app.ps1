# Packages the Windows app: release build + the Swift runtime DLLs it needs.
#
#   pwsh scripts/make_windows_app.ps1 -Version 0.7.0
#
# Output: dist/BurnRate-<version>-windows-x64.zip
param(
    [string]$Version = "0.0.0"
)

$ErrorActionPreference = "Stop"

Write-Host "==> swift build -c release --product BurnRate"
# Link as a GUI subsystem app so launching BurnRate.exe doesn't open a console
# window. If the entry-point flags are rejected by the toolchain, fall back to
# the default console link (the app still works).
swift build -c release --product BurnRate `
    -Xlinker /SUBSYSTEM:WINDOWS `
    -Xlinker /ENTRY:mainCRTStartup
if ($LASTEXITCODE -ne 0) {
    Write-Warning "GUI-subsystem link failed; falling back to a console build"
    swift build -c release --product BurnRate
    if ($LASTEXITCODE -ne 0) { throw "swift build failed" }
}

$binary = ".build\release\BurnRate.exe"
if (-not (Test-Path $binary)) { throw "error: $binary not found" }

$stage = "dist\BurnRate-$Version-windows-x64"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

Copy-Item $binary "$stage\BurnRate.exe"

# Ship the Swift runtime DLLs alongside the exe (the toolchain's bin directory).
$swiftExe = (Get-Command swift).Source
$swiftBin = Split-Path $swiftExe
Get-ChildItem "$swiftBin\*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item $_.FullName "$stage\" -Force
}

Compress-Archive -Path "$stage\*" -DestinationPath "$stage.zip" -Force
Write-Host "==> done: $stage.zip"
Write-Host "    unzip and run BurnRate.exe"
