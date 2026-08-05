$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$HarnessPath = Join-Path $Root "scripts\run-installed-installer-qa.ps1"
$WorkflowPaths = @(Get-ChildItem -LiteralPath (Join-Path $Root ".github\workflows") -File -Filter "*.yml" | Select-Object -ExpandProperty FullName)
$RustDesktopPath = Join-Path $Root "apps\desktop\src-tauri\src\lib.rs"
$Harness = Get-Content -LiteralPath $HarnessPath -Raw
$Workflow = ($WorkflowPaths | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"
$RustDesktop = Get-Content -LiteralPath $RustDesktopPath -Raw

if ($WorkflowPaths.Count -ne 1 -or [IO.Path]::GetFileName($WorkflowPaths[0]) -ne "windows-installer-qa.yml") {
    throw "Exactly one repository workflow is permitted: windows-installer-qa.yml."
}
if ($Workflow -notmatch '(?ms)^on:\s*\r?\n\s+workflow_dispatch:\s*(?:\r?\n|$)') {
    throw "Installer QA must be manual-only through workflow_dispatch."
}
foreach ($AutomaticTrigger in @("pull_request:", "pull_request_target:", "push:", "schedule:", "workflow_call:", "workflow_run:", "repository_dispatch:", "release:")) {
    if ($Workflow -match "(?m)^\s+$([regex]::Escape($AutomaticTrigger))") {
        throw "Automatic workflow trigger '$AutomaticTrigger' is forbidden."
    }
}
if ($Workflow -notmatch '(?m)^concurrency:\s*$' -or $Workflow -notmatch '(?m)^\s+cancel-in-progress:\s+true\s*$') {
    throw "Manual installer QA must cancel an accidental duplicate run."
}
if ($Workflow -match '(?im)^\s*environment\s*:') { throw "Deployment environments are forbidden." }
if ($Workflow -match '(?i)\$\{\{\s*secrets\.') { throw "Secret-dependent workflow steps are forbidden." }
if ($Workflow -match '(?im)^\s*(?:contents|actions|checks|deployments|id-token|packages|pages|pull-requests|security-events|statuses)\s*:\s*write\s*$') {
    throw "Publishing or write permissions are forbidden."
}
if ($Workflow -notmatch '(?ms)^permissions:\s*\r?\n\s+contents:\s+read\s*(?:\r?\n|$)') {
    throw "Workflow permissions must be explicitly read-only."
}
$ActionUses = @([regex]::Matches($Workflow, '(?im)^\s*uses:\s*([^\s#]+)') | ForEach-Object { $_.Groups[1].Value })
if ($ActionUses.Count -eq 0 -or @($ActionUses | Where-Object { $_ -notmatch '@[0-9a-f]{40}$' }).Count -ne 0) {
    throw "Every third-party action must be pinned to a full commit SHA."
}
if (@([regex]::Matches($Workflow, '(?im)^\s*runs-on:\s*windows-2025\s*$')).Count -ne 2) {
    throw "Installer QA must contain exactly two standard windows-2025 jobs."
}
if (@([regex]::Matches($Workflow, '(?im)^\s*timeout-minutes:\s*45\s*$')).Count -ne 2) {
    throw "Both installer QA jobs must keep the bounded 45-minute timeout."
}
if (@([regex]::Matches($Workflow, '(?im)^\s*persist-credentials:\s*false\s*$')).Count -ne 2) {
    throw "Both checkouts must disable persisted credentials."
}
if ($Workflow -match '(?i)\b(?:gh\s+release|npm\s+publish|cargo\s+publish|twine\s+upload)\b') {
    throw "Publishing commands are forbidden in installer QA."
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
Assert-Contains $Workflow "runs-on: windows-2025" "Installer QA is not pinned to the GitHub-hosted Windows image."
if ($Workflow -match '(?im)^\s*runs-on:\s*\[?\s*self-hosted') { throw "Self-hosted runner use is forbidden." }
if ($Workflow -match '(?im)^\s*continue-on-error\s*:\s*true') { throw "A safety assertion cannot use continue-on-error." }

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
