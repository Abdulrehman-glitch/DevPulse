$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# This gate is deliberately installer-free. It launches only the packaged
# sidecar smoke test; the desktop production executable is built but not run.
# Generated validation output stays under the repository's ignored QA roots.
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$PreviousPythonPath = $env:PYTHONPATH
Push-Location $Root
try {
    function Invoke-LocalStep([string]$Name, [scriptblock]$Action) {
        Write-Host "`n=== $Name ===" -ForegroundColor Cyan
        & $Action
        if ($LASTEXITCODE -ne 0) {
            throw "$Name failed with exit code $LASTEXITCODE."
        }
    }

    Invoke-LocalStep "Version synchronization" { npm run versions:check }
    Invoke-LocalStep "Frontend format" { npm run format:check }
    Invoke-LocalStep "Frontend lint" { npm run lint }
    Invoke-LocalStep "TypeScript" { npm run typecheck }
    Invoke-LocalStep "Frontend tests" { npm test }
    Invoke-LocalStep "Frontend production build" { npm run build }
    Invoke-LocalStep "Brand asset contract" { node scripts/test-brand-assets.mjs }

    $Python = Join-Path $Root ".venv\Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
        throw "The repository .venv is missing. Create it and install requirements-ci.lock before running local validation."
    }
    $env:PYTHONPATH = Join-Path $Root "services\local-core"
    Invoke-LocalStep "Python format" { & $Python -m ruff format --check . }
    Invoke-LocalStep "Python lint" { & $Python -m ruff check . }
    Invoke-LocalStep "Python tests" { & $Python -m pytest }
    $OpenApiPath = Join-Path $Root "services\local-core\openapi\v1.json"
    $OpenApiBefore = (Get-FileHash -LiteralPath $OpenApiPath -Algorithm SHA256).Hash
    Invoke-LocalStep "OpenAPI generation" { npm run core:openapi }
    $OpenApiAfter = (Get-FileHash -LiteralPath $OpenApiPath -Algorithm SHA256).Hash
    if ($OpenApiAfter -ne $OpenApiBefore) {
        throw "OpenAPI generation is not stable; regenerate and review the contract before validation."
    }
    Invoke-LocalStep "npm complete dependency audit" { npm audit }
    Invoke-LocalStep "npm production dependency audit" { npm audit --omit=dev }
    Invoke-LocalStep "Dependency compliance outputs" { & $Python scripts/generate-dependency-compliance.py --check }
    $WheelDirectory = Join-Path $Root ".qa-runtime\python-dist"
    New-Item -ItemType Directory -Force -Path $WheelDirectory | Out-Null
    Invoke-LocalStep "Python package build" {
        & $Python -m pip wheel --no-deps --no-build-isolation --wheel-dir $WheelDirectory .
    }

    Invoke-LocalStep "Artificial performance matrix" { npm run performance:matrix }
    Invoke-LocalStep "Tauri configuration" { npm run tauri:check }
    Invoke-LocalStep "Workflow storage and runner policy" { npm run workflows:check }
    Invoke-LocalStep "JSON validation" { npm run json:check }
    Invoke-LocalStep "Markdown links" { npm run docs:check }
    Invoke-LocalStep "Uninstall-entry regression tests" { .\scripts\test-uninstall-entry-filter.ps1 }
    Invoke-LocalStep "Installer-QA harness regression tests" { .\scripts\test-installed-installer-qa-harness.ps1 }
    Invoke-LocalStep "Installer archive inspection regression tests" { .\scripts\test-installer-archive-inspection.ps1 }
    # Tauri validates externalBin paths during cargo check. Match CI by building
    # the authentic sidecar before any Rust/Tauri compilation step.
    Invoke-LocalStep "Packaged sidecar build" { npm run sidecar:build }

    Push-Location (Join-Path $Root "apps\desktop\src-tauri")
    try {
        $PreviousRustFlags = $env:RUSTFLAGS
        $env:RUSTFLAGS = if ($PreviousRustFlags) { "$PreviousRustFlags -Dwarnings" } else { "-Dwarnings" }
        Invoke-LocalStep "Rust format" { cargo fmt --all -- --check }
        Invoke-LocalStep "Rust check" { cargo check --locked }
        Invoke-LocalStep "Rust release check" { cargo check --release --locked }
        Invoke-LocalStep "Rust tests" { cargo test --locked }
        $ClippyInstalled = if (Get-Command rustup -ErrorAction SilentlyContinue) {
            @(& rustup component list --installed | Where-Object { $_ -like "clippy-*" }).Count -gt 0
        } else {
            $false
        }
        if ($ClippyInstalled) {
            Invoke-LocalStep "Rust clippy" { cargo clippy --locked --all-targets -- -D warnings }
        }
        else {
            Write-Warning "Clippy is not installed; install it in an authorised toolchain before relying on this optional lint gate."
        }
    }
    finally {
        if ($null -eq $PreviousRustFlags) {
            Remove-Item Env:RUSTFLAGS -ErrorAction SilentlyContinue
        }
        else {
            $env:RUSTFLAGS = $PreviousRustFlags
        }
        Pop-Location
    }

    Invoke-LocalStep "SBOM generation" { npm run sbom:generate }
    Invoke-LocalStep "Packaged sidecar authenticated startup/shutdown" { npm run sidecar:test }
    Invoke-LocalStep "Unbundled production desktop build" {
        npm --workspace @devpulse/desktop run tauri -- build --no-bundle --ci --no-sign -- --locked
    }

    Write-Host "`nLocal validation completed. Installer creation and execution were not performed." -ForegroundColor Green
}
finally {
    if ($null -eq $PreviousPythonPath) {
        Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
    }
    else {
        $env:PYTHONPATH = $PreviousPythonPath
    }
    Pop-Location
}
