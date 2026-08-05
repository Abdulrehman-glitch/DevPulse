$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# This gate is deliberately installer-free. It may launch only the uninstalled
# release executable through release:qa and the packaged sidecar through
# sidecar:test, both of which write under the repository's ignored QA roots.
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
    Invoke-LocalStep "npm production dependency audit" { npm audit --audit-level=high --omit=dev }
    Invoke-LocalStep "Python dependency audit" { & $Python -m pip_audit -r requirements-ci.lock }
    $CargoAudit = Get-Content -LiteralPath (Join-Path $Root "evidence\beta1\cargo-audit-summary.json") -Raw | ConvertFrom-Json
    if ($CargoAudit.vulnerabilitiesFound -or $CargoAudit.actionableVulnerabilityCount -ne 0 -or $CargoAudit.criticalFindings -ne 0 -or $CargoAudit.highFindings -ne 0) {
        throw "The committed cargo-audit summary contains actionable findings."
    }
    Write-Host "Cargo audit summary verified: zero actionable findings; cargo-audit executable is not installed locally." -ForegroundColor Yellow

    Invoke-LocalStep "Artificial performance matrix" { npm run performance:matrix }
    Invoke-LocalStep "Tauri configuration" { npm run tauri:check }
    Invoke-LocalStep "JSON validation" { npm run json:check }
    Invoke-LocalStep "Markdown links" { npm run docs:check }
    Invoke-LocalStep "Uninstall-entry regression tests" { .\scripts\test-uninstall-entry-filter.ps1 }
    Invoke-LocalStep "Installer-QA harness regression tests" { .\scripts\test-installed-installer-qa-harness.ps1 }

    Push-Location (Join-Path $Root "apps\desktop\src-tauri")
    try {
        Invoke-LocalStep "Rust format" { cargo fmt --all -- --check }
        Invoke-LocalStep "Rust check" { cargo check --locked }
        Invoke-LocalStep "Rust tests" { cargo test --locked }
    }
    finally { Pop-Location }

    Invoke-LocalStep "SBOM generation" { npm run sbom:generate }
    Invoke-LocalStep "Packaged sidecar build" { npm run sidecar:build }
    Invoke-LocalStep "Packaged sidecar authenticated startup/shutdown" { npm run sidecar:test }
    Invoke-LocalStep "Uninstalled release executable QA" { npm run release:qa }

    Write-Host "`nLocal validation completed. Installer execution was not performed." -ForegroundColor Green
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
