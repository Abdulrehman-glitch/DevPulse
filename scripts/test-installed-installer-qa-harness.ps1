$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$HarnessPath = Join-Path $Root "scripts\run-installed-installer-qa.ps1"
$WorkflowDirectory = Join-Path $Root ".github\workflows"
$WorkflowPaths = @(
    if (Test-Path -LiteralPath $WorkflowDirectory -PathType Container) {
        Get-ChildItem -LiteralPath $WorkflowDirectory -File
    }
)
$RustDesktopPath = Join-Path $Root "apps\desktop\src-tauri\src\lib.rs"
$Harness = Get-Content -LiteralPath $HarnessPath -Raw
$RustDesktop = Get-Content -LiteralPath $RustDesktopPath -Raw

$ExpectedWorkflowNames = @("ci.yml", "release-qa.yml", "windows-compatibility.yml")
$ActualWorkflowNames = @($WorkflowPaths | Select-Object -ExpandProperty Name | Sort-Object)
if (@(Compare-Object $ExpectedWorkflowNames $ActualWorkflowNames).Count -ne 0) {
    throw "The public repository workflow inventory changed without harness review."
}
$WorkflowText = @($WorkflowPaths | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
$ReleaseWorkflow = Get-Content -LiteralPath (Join-Path $WorkflowDirectory "release-qa.yml") -Raw
$CompatibilityWorkflow = Get-Content -LiteralPath (Join-Path $WorkflowDirectory "windows-compatibility.yml") -Raw
if ($WorkflowText -match '(?m)^\s*pull_request_target\s*:') {
    throw "Public workflows must not use pull_request_target."
}
if (-not $ReleaseWorkflow.Contains("workflow_dispatch:")) { throw "Release QA lost its manual-only trigger." }
if (-not $ReleaseWorkflow.Contains("runs-on: windows-2025")) { throw "Release QA lost its standard Windows runner." }
if ($ReleaseWorkflow -match '(?m)^\s{2}(?:push|pull_request|schedule)\s*:') {
    throw "Release QA must not run on push, pull request, or a schedule."
}
if (-not $CompatibilityWorkflow.Contains("workflow_dispatch:")) { throw "Windows compatibility lost its manual-only trigger." }
if (-not $CompatibilityWorkflow.Contains("windows-2022") -or -not $CompatibilityWorkflow.Contains("windows-2025")) {
    throw "Windows compatibility lost its bounded standard-runner matrix."
}
if ($CompatibilityWorkflow -match 'actions/upload-artifact@') { throw "Windows compatibility must not persist workflow artifacts." }
if ($CompatibilityWorkflow -match '(?m)^\s{2}(?:push|pull_request|schedule)\s*:') {
    throw "Windows compatibility must not run on push, pull request, or a schedule."
}

function Assert-Contains([string]$Text, [string]$Needle, [string]$Message) {
    if (-not $Text.Contains($Needle)) { throw $Message }
}

$ParseErrors = $null
$Tokens = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $HarnessPath,
    [ref]$Tokens,
    [ref]$ParseErrors
)
if ($ParseErrors.Count -ne 0) {
    throw "Installed installer-QA harness has PowerShell parse errors: $($ParseErrors.Message -join '; ')"
}

Assert-Contains $Harness '$env:GITHUB_ACTIONS -ne "true"' "Harness lost its GitHub Actions execution gate."
Assert-Contains $Harness '$env:RUNNER_ENVIRONMENT -ne "github-hosted"' "Harness lost its GitHub-hosted runner-environment gate."
Assert-Contains $Harness '$env:DEVPULSE_DISPOSABLE_RUNNER -ne "github-hosted"' "Harness lost its disposable-runner gate."

foreach ($Protected in @(
    'Join-Path $env:APPDATA "com.devpulse.desktop"',
    'Join-Path $env:APPDATA "DevPulse"',
    'Join-Path $env:LOCALAPPDATA "com.devpulse.desktop"'
)) {
    Assert-Contains $Harness $Protected "A protected production-AppData path disappeared from the audit."
}
foreach ($Evidence in @(
    "evidence-timeline.jsonl", "appdata-write-timeline.json", "immediate-close-results.json",
    "normal-close-results.json", "failure-recovery-results.json", "final-clean-state.json",
    "qa-gate-refusal-results.json", "screenshot-index.json", "final-installer-qa-evidence.html"
)) {
    Assert-Contains $Harness $Evidence "Required evidence output $Evidence is missing."
}

Assert-Contains $Harness '1..3 | ForEach-Object' "The harness no longer performs three immediate-close probes."
Assert-Contains $Harness 'Get-UninstallerFromRegistry' "The uninstaller is no longer resolved from the exact registry entry."
Assert-Contains $Harness 'Remove-ValidatedQaRuntime' "Canonical QA cleanup validation is missing."
Assert-Contains $Harness '[System.IO.FileAttributes]::ReparsePoint' "QA cleanup lost junction/symlink refusal."
Assert-Contains $Harness 'production-appdata-contamination' "Production-AppData contamination is no longer a hard evidence event."
Assert-Contains $Harness 'globalProcessNameTerminationUsed = $false' "No-global-termination evidence is missing."
Assert-Contains $Harness 'Test-LifecycleProcessIdentity' "Installed QA does not protect against PID reuse."
Assert-Contains $Harness 'creationUtc' "Installed QA does not record process creation identity."
Assert-Contains $Harness 'Test-LifecycleChildSnapshotRelationship' "Installed QA does not reject stale parent PID relationships."
Assert-Contains $Harness 'UseShellExecute = $false' "Installed QA lost its child-only environment launch boundary."
Assert-Contains $Harness 'DEVPULSE_DATA_DIR = $QaRoot' "The canonical QA root is not propagated to the installed child."
Assert-Contains $Harness '$QaRootLeaf = "DevPulse-QA-installed"' "The installed QA root can no longer exercise safe alternate path names."
Assert-Contains $Harness '$QaSandboxParent = [IO.Path]::GetPathRoot($env:SystemRoot)' "Installed QA no longer avoids runner-owned workspace reparse aliases."
Assert-Contains $Harness '$Candidate -ne [System.IO.Path]::GetFullPath($QaRoot)' "QA cleanup is no longer restricted to the exact owned root."
Assert-Contains $Harness 'APPDATA = $QaRoamingAppData' "Roaming AppData is not isolated for the installed child."
Assert-Contains $Harness 'LOCALAPPDATA = $QaLocalAppData' "Local AppData is not isolated for the installed child."
Assert-Contains $Harness 'Invoke-QaGateRefusalTests' "Partial QA launches are no longer tested for safe refusal."
Assert-Contains $Harness 'environmentMatchesCanonicalPlan' "Cross-component canonical-path verification is missing."
Assert-Contains $RustDesktop 'window.create = false' "QA no longer suppresses Tauri's unsafe auto-window path resolution."
Assert-Contains $RustDesktop 'WebviewWindowBuilder::from_config' "QA no longer constructs the configured window explicitly."
Assert-Contains $RustDesktop '.data_directory(data_directory.clone())' "QA WebView no longer receives an explicit absolute data directory."

if ($Harness -match '(?im)^\s*\$env:DEVPULSE_(?:QA|INSTALL|DATA)[A-Z_]*\s*=') {
    throw "Installed QA must not mutate the evidence harness process environment."
}

if ($Harness -match '(?i)Stop-Process\s+-(Name|InputObject).*devpulse|taskkill(?:\.exe)?\s+.*/IM') {
    throw "Harness contains forbidden global process-name termination."
}
if ($Harness -match '(?i)Remove-Item\s+(?:-Path\s+)?(?:[A-Z]:\\|\$env:(?:USERPROFILE|APPDATA|LOCALAPPDATA))\s+-Recurse') {
    throw "Harness contains an unbounded recursive deletion target."
}

. (Join-Path $Root "scripts\lib\lifecycle-harness.ps1")
$IdentityMap = @{}
[void](Register-LifecycleProcessIdentity $IdentityMap $PID)
if (-not (Test-LifecycleProcessIdentity $IdentityMap $PID)) {
    throw "Process identity regression test could not recognize the current process."
}
$IdentityMap[[string]$PID] = [ordered]@{ processId = $PID; name = "process-that-does-not-exist.exe"; creationUtc = $null; executablePath = $null }
if (Test-LifecycleProcessIdentity $IdentityMap $PID) {
    throw "Process identity regression test accepted a reused PID with a different executable."
}

Write-Host "Installed installer-QA harness regression checks passed."
