$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Python = Join-Path $Root ".venv\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $Python)) {
    throw "Create .venv and install .[dev] before building the sidecar."
}
$Rustc = Get-Command rustc -ErrorAction SilentlyContinue
if (-not $Rustc) {
    throw "Rust is required to determine the Tauri target triple."
}
$RustInfo = & rustc -vV
$HostLine = $RustInfo | Where-Object { $_ -like "host:*" }
$Target = ($HostLine -split ":", 2)[1].Trim()
if (-not $Target) {
    throw "Could not determine the Rust host target."
}
$BuildDirectory = Join-Path $Root ".tmp\sidecar-build"
$DestinationDirectory = Join-Path $Root "apps\desktop\src-tauri\binaries"
New-Item -ItemType Directory -Force -Path $BuildDirectory, $DestinationDirectory | Out-Null
$env:PYINSTALLER_CONFIG_DIR = Join-Path $BuildDirectory "config"
# Tauri launches the console-subsystem sidecar with CREATE_NO_WINDOW and inherited
# pipes. PyInstaller's windowed mode replaces Python stdio with null objects, which
# would break the secret stdin launch channel and non-secret readiness frame.
& $Python -m PyInstaller `
    --noconfirm `
    --clean `
    --onefile `
    --console `
    --name devpulse-local-core `
    --distpath (Join-Path $BuildDirectory "dist") `
    --workpath (Join-Path $BuildDirectory "work") `
    --specpath $BuildDirectory `
    (Join-Path $Root "services\local-core\devpulse_core\main.py")
if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed." }
$Extension = if ($IsWindows -or $env:OS -eq "Windows_NT") { ".exe" } else { "" }
$Source = Join-Path $BuildDirectory "dist\devpulse-local-core$Extension"
$Destination = Join-Path $DestinationDirectory "devpulse-local-core-$Target$Extension"
Copy-Item -LiteralPath $Source -Destination $Destination -Force
Write-Host "Sidecar ready: $Destination"
