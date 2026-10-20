# PowerShell script for building Flutter Windows release and compiling Inno Setup installer
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
Set-Location $ProjectRoot

# Extract version from pubspec.yaml
$Version = "1.0.0+1"
if (Test-Path "pubspec.yaml") {
    $VersionLine = Select-String -Path "pubspec.yaml" -Pattern "^version:\s*(.+)$" | Select-Object -First 1
    if ($VersionLine -and $VersionLine.Matches.Groups.Count -gt 1) {
        $Version = $VersionLine.Matches.Groups[1].Value.Trim()
    }
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Building ARA Assessment Windows Release & Installer" -ForegroundColor Cyan
Write-Host " Version: $Version" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

Write-Host "==> Running Flutter build windows (release)..." -ForegroundColor Yellow
& fvm flutter build windows --release
if ($LASTEXITCODE -ne 0) {
    Write-Error "Flutter build windows failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Host "==> Detecting Inno Setup Compiler (ISCC)..." -ForegroundColor Yellow
$IsccPath = $null
if (Get-Command "iscc" -ErrorAction SilentlyContinue) {
    $IsccPath = "iscc"
} elseif (Test-Path "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") {
    $IsccPath = "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
} elseif (Test-Path "C:\Program Files (x86)\Inno Setup 6\ISCC.exe") {
    $IsccPath = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
} elseif (Test-Path "C:\Program Files\Inno Setup 6\ISCC.exe") {
    $IsccPath = "C:\Program Files\Inno Setup 6\ISCC.exe"
}

if (-not $IsccPath) {
    Write-Error "Inno Setup compiler (ISCC.exe) not found. Please install Inno Setup 6 from https://jrsoftware.org/isdl.php"
    exit 1
}

Write-Host "==> Compiling Windows Installer with Inno Setup ($IsccPath)..." -ForegroundColor Yellow
& $IsccPath "/DMyAppVersion=$Version" "inno_setup.iss"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Inno Setup compilation failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

$InstallerPath = Join-Path $ProjectRoot "build\windows\ARA_Assessment_Setup.exe"
if (Test-Path $InstallerPath) {
    $Item = Get-Item $InstallerPath
    $SizeMB = [math]::Round($Item.Length / 1MB, 2)
    Write-Host "`n==========================================================" -ForegroundColor Green
    Write-Host " [SUCCESS] Windows Installer created successfully!" -ForegroundColor Green
    Write-Host " File : $($Item.FullName)" -ForegroundColor Green
    Write-Host " Size : $SizeMB MB" -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Green
} else {
    Write-Warning "Build completed, but $InstallerPath was not found."
}
