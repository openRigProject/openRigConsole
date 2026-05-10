# build_windows_installer.ps1 — Build openRig Console and package as a Windows installer.
#
# Usage (run from the openRigConsole project root on Windows):
#   .\scripts\build_windows_installer.ps1 [--skip-build]
#
#   --skip-build   Skip the flutter build step (use existing build\windows\...)
#
# Requirements:
#   - Flutter SDK in PATH
#   - Inno Setup 6 installed (https://jrsoftware.org/isdl.php)
#     Default install path: C:\Program Files (x86)\Inno Setup 6\ISCC.exe
#
# Output: build\openRigConsole-<version>-windows-setup.exe

param(
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectDir = (Get-Item "$PSScriptRoot\..").FullName
Set-Location $ProjectDir

# ── Version ───────────────────────────────────────────────────────────────────
$pubspec = Get-Content "pubspec.yaml" -Raw
if ($pubspec -match '(?m)^version:\s*(\S+)') {
    $Version = $Matches[1] -replace '\+.*', ''   # strip build number
} else {
    Write-Error "Could not read version from pubspec.yaml"
    exit 1
}

$ReleasDir = "build\windows\x64\runner\Release"
$SetupExe  = "build\openRigConsole-${Version}-windows-setup.exe"

Write-Host "==> openRig Console Windows installer builder"
Write-Host "    Version : $Version"
Write-Host "    Output  : $SetupExe"

# ── Flutter build ─────────────────────────────────────────────────────────────
if (-not $SkipBuild) {
    Write-Host "==> Building Flutter release..."
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { Write-Error "flutter build failed"; exit 1 }
} else {
    Write-Host "==> Skipping build (--skip-build)"
}

if (-not (Test-Path "$ReleasDir\openrig_console.exe")) {
    Write-Error "App not found at $ReleasDir\openrig_console.exe — run without --skip-build"
    exit 1
}

# ── Locate Inno Setup compiler ────────────────────────────────────────────────
$IsccCandidates = @(
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe",
    "iscc.exe"   # if in PATH
)
$Iscc = $null
foreach ($c in $IsccCandidates) {
    if (Get-Command $c -ErrorAction SilentlyContinue) { $Iscc = $c; break }
    if (Test-Path $c) { $Iscc = $c; break }
}
if (-not $Iscc) {
    Write-Error @"
Inno Setup not found. Install it from https://jrsoftware.org/isdl.php
or add ISCC.exe to your PATH.
"@
    exit 1
}
Write-Host "==> Using Inno Setup: $Iscc"

# ── Compile installer ─────────────────────────────────────────────────────────
Write-Host "==> Compiling installer..."
& $Iscc `
    "/DAppVersion=$Version" `
    "scripts\installer.iss"

if ($LASTEXITCODE -ne 0) { Write-Error "Inno Setup compilation failed"; exit 1 }

if (-not (Test-Path $SetupExe)) {
    # Inno Setup may have used a slightly different name — find it
    $found = Get-ChildItem "build\openRigConsole-*-windows-setup.exe" | Select-Object -First 1
    if ($found) { $SetupExe = $found.FullName }
}

$size = [math]::Round((Get-Item $SetupExe).Length / 1MB, 1)
Write-Host ""
Write-Host "Done: $SetupExe  ($size MB)" -ForegroundColor Green
