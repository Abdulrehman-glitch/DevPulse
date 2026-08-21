$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "lib\lifecycle-harness.ps1")

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace DevPulseQa {
    public static class NativeMethods {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    }
}
"@

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$QaRoot = Join-Path $Root ".qa-runtime"
$ExpectedQaRoot = [System.IO.Path]::GetFullPath((Join-Path $Root ".qa-runtime"))
if ([System.IO.Path]::GetFullPath($QaRoot) -ne $ExpectedQaRoot -or $ExpectedQaRoot -notlike "$Root\*") {
    throw "The release QA root is not the dedicated workspace QA directory."
}
New-Item -ItemType Directory -Force -Path $QaRoot | Out-Null
$AuditDirectory = Join-Path $QaRoot "audit"
New-Item -ItemType Directory -Force -Path $AuditDirectory | Out-Null
$ReportPath = Join-Path $AuditDirectory "release-qa-report.json"
$Version = (Get-Content -LiteralPath (Join-Path $Root "VERSION") -Raw).Trim()
$CommitSha = (& git rev-parse HEAD).Trim()
$LifecycleRecorder = New-LifecycleRecorder -Directory $AuditDirectory -Scenario "uninstalled-release-qa" -Version $Version -CommitSha $CommitSha
$Script:ReleaseQaProcessIdentities = @{}

function Find-ReleaseExecutable {
    $ReleaseDirectory = Join-Path $Root "apps\desktop\src-tauri\target\release"
    if (-not (Test-Path -LiteralPath $ReleaseDirectory -PathType Container)) {
        throw "The Rust release directory does not exist. Build the release executable first."
    }
    $Candidates = @(Get-ChildItem -LiteralPath $ReleaseDirectory -File -Filter "*.exe" | Where-Object {
        $_.FullName -notmatch '\\(deps|build|bundle)\\' -and
        $_.Name -notlike "*-local-core*" -and
        $_.Name -notlike "*installer*" -and
        $_.Name -notlike "*setup*"
    })
    $Branded = @($Candidates | Where-Object {
        $_.VersionInfo.ProductName -eq "DevPulse" -or
        $_.VersionInfo.FileDescription -like "*DevPulse*"
    })
    if ($Branded.Count -eq 1) { return $Branded[0].FullName }
    if ($Candidates.Count -eq 1) { return $Candidates[0].FullName }
    throw "Could not unambiguously locate the compiled DevPulse release executable."
}

function Get-PathMetadataSnapshot([string[]]$Paths, [switch]$Recursive) {
    $Items = @()
    foreach ($Path in $Paths) {
        if (-not (Test-Path -LiteralPath $Path)) {
            $Items += [ordered]@{ path = $Path; exists = $false }
            continue
        }
        $Targets = @((Get-Item -LiteralPath $Path -Force))
        if ($Recursive) {
            $Targets += @(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop)
        }
        foreach ($Target in $Targets) {
            $Items += [ordered]@{
                path = $Target.FullName
                exists = $true
                directory = $Target.PSIsContainer
                length = if ($Target.PSIsContainer) { $null } else { $Target.Length }
                lastWriteUtc = $Target.LastWriteTimeUtc.ToString("o")
                attributes = $Target.Attributes.ToString()
            }
        }
    }
    return @($Items | Sort-Object { $_.path })
}

function Get-ProductionSnapshot {
    $Locations = @(
        (Join-Path $env:APPDATA "com.devpulse.desktop"),
        (Join-Path $env:APPDATA "DevPulse")
    ) | Select-Object -Unique
    return Get-PathMetadataSnapshot -Paths $Locations -Recursive
}

function Get-ProtectedSentinelSnapshot {
    $Sentinels = @(
        $env:WINDIR,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        (Join-Path $env:USERPROFILE "Documents"),
        (Join-Path $env:USERPROFILE "Desktop"),
        (Join-Path $env:USERPROFILE "Downloads"),
        (Join-Path $env:USERPROFILE "OneDrive")
    ) | Where-Object { $_ } | Select-Object -Unique
    # Deliberately metadata-only: never enumerate these protected directories.
    return Get-PathMetadataSnapshot -Paths $Sentinels
}

function Convert-SnapshotToStableJson($Snapshot) {
    return ($Snapshot | ConvertTo-Json -Depth 8 -Compress)
}

function Get-ChildProcessIds([int]$ParentId) {
    if (-not (Test-LifecycleProcessIdentity $Script:ReleaseQaProcessIdentities $ParentId)) { return @() }
    return @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ParentId" -ErrorAction Stop |
        ForEach-Object { [int]$_.ProcessId })
}

function Expand-OwnedProcessIds([System.Collections.Generic.HashSet[int]]$Owned) {
    $Processes = @(Get-LifecycleProcessTable | ForEach-Object {
        [pscustomobject]@{
            processId = [int]$_.processId
            id = [int]$_.processId
            parent = [int]$_.parentProcessId
            name = [string]$_.name
            executablePath = [string]$_.executablePath
            creationUtc = $_.creationUtc
        }
    })
    $ProcessMap = @{}
    foreach ($Process in $Processes) { $ProcessMap[[string]$Process.id] = $Process }
    $ExpectedDescendants = @("devpulse-local-core.exe", "msedgewebview2.exe")
    $Changed = $true
    while ($Changed) {
        $Changed = $false
        foreach ($Candidate in $Processes) {
            $Parent = $ProcessMap[[string]$Candidate.parent]
            if ($Candidate.name -in $ExpectedDescendants -and
                (Test-LifecycleChildSnapshotRelationship $Script:ReleaseQaProcessIdentities $Parent $Candidate) -and
                $Owned.Add($Candidate.id)) {
                [void](Register-LifecycleProcessIdentity $Script:ReleaseQaProcessIdentities $Candidate.id)
                $Changed = $true
            }
        }
    }
}

function Test-ProcessAlive([int]$Id) {
    return Test-LifecycleProcessIdentity $Script:ReleaseQaProcessIdentities $Id
}

function Start-DevPulseQa(
    [string]$Executable,
    [bool]$Automation,
    [bool]$FailStart,
    [bool]$FailAfterReady = $false
) {
    $Previous = @{
        Mode = [Environment]::GetEnvironmentVariable("DEVPULSE_QA_MODE", "Process")
        Root = [Environment]::GetEnvironmentVariable("DEVPULSE_QA_ROOT", "Process")
        Automation = [Environment]::GetEnvironmentVariable("DEVPULSE_QA_AUTOMATION", "Process")
        Fail = [Environment]::GetEnvironmentVariable("DEVPULSE_QA_FAIL_START", "Process")
        FailAfterReady = [Environment]::GetEnvironmentVariable("DEVPULSE_QA_FAIL_AFTER_READY", "Process")
    }
    try {
        $env:DEVPULSE_QA_MODE = "1"
        $env:DEVPULSE_QA_ROOT = $QaRoot
        $env:DEVPULSE_QA_AUTOMATION = if ($Automation) { "1" } else { "0" }
        $env:DEVPULSE_QA_FAIL_START = if ($FailStart) { "1" } else { "0" }
        $env:DEVPULSE_QA_FAIL_AFTER_READY = if ($FailAfterReady) { "1" } else { "0" }
        $Process = Start-Process -FilePath $Executable -WorkingDirectory $Root -PassThru
        [void](Register-LifecycleProcessIdentity $Script:ReleaseQaProcessIdentities $Process.Id)
        Write-LifecycleTransition -Recorder $LifecycleRecorder -State "native-process-created" -DesktopPid $Process.Id
        return $Process
    }
    finally {
        [Environment]::SetEnvironmentVariable("DEVPULSE_QA_MODE", $Previous.Mode, "Process")
        [Environment]::SetEnvironmentVariable("DEVPULSE_QA_ROOT", $Previous.Root, "Process")
        [Environment]::SetEnvironmentVariable("DEVPULSE_QA_AUTOMATION", $Previous.Automation, "Process")
        [Environment]::SetEnvironmentVariable("DEVPULSE_QA_FAIL_START", $Previous.Fail, "Process")
        [Environment]::SetEnvironmentVariable("DEVPULSE_QA_FAIL_AFTER_READY", $Previous.FailAfterReady, "Process")
    }
}

function Wait-ForWindow([System.Diagnostics.Process]$Process, [int]$TimeoutSeconds = 15) {
    $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $Deadline) {
        if ($Process.HasExited) {
            Write-LifecycleTransition -Recorder $LifecycleRecorder -State "process-exited-before-window" -DesktopPid $Process.Id
            return $false
        }
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
            Write-LifecycleTransition -Recorder $LifecycleRecorder -State "native-window-created" -DesktopPid $Process.Id -Details @{ handle = $Process.MainWindowHandle.ToInt64() }
            return $true
        }
        Start-Sleep -Milliseconds 50
    }
    Write-LifecycleTransition -Recorder $LifecycleRecorder -State "native-window-timeout" -DesktopPid $Process.Id -Details @{ timeoutSeconds = $TimeoutSeconds }
    return $false
}

function Wait-ForFile([string]$Path, [int]$TimeoutSeconds) {
    $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $Deadline) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Wait-ForRecoveryEvidence([string]$Path, [int]$TimeoutSeconds) {
    $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $Deadline) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                $Events = @(Get-Content -LiteralPath $Path | ForEach-Object { $_ | ConvertFrom-Json })
                $Ready = @($Events | Where-Object { $_.state -eq "core-authenticated-ready" }).Count
                $Scheduled = @($Events | Where-Object { $_.state -eq "core-recovery-scheduled" }).Count
                $Injected = @($Events | Where-Object { $_.state -eq "qa-post-readiness-failure-injected" }).Count
                if ($Ready -eq 2 -and $Scheduled -eq 1 -and $Injected -eq 1) {
                    return [ordered]@{
                        authenticatedReadyCount = $Ready
                        recoveryScheduledCount = $Scheduled
                        ownedFailureInjectionCount = $Injected
                    }
                }
            }
            catch {
                # A JSONL record may be observed between its append and newline flush.
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Bounded post-readiness recovery evidence did not complete."
}

function Stop-OwnedLaunch([System.Diagnostics.Process]$Process, [string]$Kind) {
    $Owned = [System.Collections.Generic.HashSet[int]]::new()
    [void](Register-LifecycleProcessIdentity $Script:ReleaseQaProcessIdentities $Process.Id)
    [void]$Owned.Add($Process.Id)
    Expand-OwnedProcessIds $Owned
    if (-not $Process.HasExited) {
        $Process.Refresh()
        $Window = $Process.MainWindowHandle
        Write-LifecycleTransition -Recorder $LifecycleRecorder -State "close-requested" -DesktopPid $Process.Id -Details @{ kind = $Kind; windowHandlePresent = $Window -ne [IntPtr]::Zero }
        if ($Window -eq [IntPtr]::Zero -or
            -not [DevPulseQa.NativeMethods]::PostMessage($Window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) {
            throw "$Kind launch did not expose a closeable native window."
        }
        # WebView2-backed Tauri windows can acknowledge WM_CLOSE without dispatching
        # the close through the managed window handle while frontend automation is
        # still settling. Use the native .NET close request as a bounded fallback;
        # the exact owned process tree is still audited below.
        $Process.Refresh()
        if (-not $Process.HasExited) {
            Write-LifecycleTransition -Recorder $LifecycleRecorder -State "close-main-window-fallback" -DesktopPid $Process.Id -Details @{ kind = $Kind }
            [void]$Process.CloseMainWindow()
        }
    }
    $Deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $Deadline -and -not $Process.HasExited) {
        Expand-OwnedProcessIds $Owned
        if (-not $Process.HasExited) { Start-Sleep -Milliseconds 250 }
    }
    $Process.Refresh()
    if (-not $Process.HasExited) {
        Write-LifecycleTransition -Recorder $LifecycleRecorder -State "close-timeout" -DesktopPid $Process.Id -OwnedPids @($Owned) -Details @{ kind = $Kind; timeoutSeconds = 30 }
        $AliveDetails = @($Owned | ForEach-Object {
            Get-Process -Id $_ -ErrorAction SilentlyContinue |
                Select-Object Id, ProcessName, MainWindowHandle
        })
        Write-Warning ("Timed-out owned process state: " + ($AliveDetails | ConvertTo-Json -Compress))
        foreach ($Id in @($Owned | Sort-Object -Descending)) {
            if (Test-ProcessAlive $Id) { Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue }
        }
        throw "$Kind launch did not close within 30 seconds. Exact owned PIDs were cleaned up."
    }
    $Process.WaitForExit()
    Write-LifecycleTransition -Recorder $LifecycleRecorder -State "desktop-process-exited" -DesktopPid $Process.Id -OwnedPids @($Owned) -Details @{ kind = $Kind; exitCode = $Process.ExitCode }
    $DescendantDeadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $Orphans = @($Owned | Where-Object { $_ -ne $Process.Id -and (Test-ProcessAlive $_) })
        if ($Orphans.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $DescendantDeadline)
    if ($Orphans.Count -gt 0) {
        $OrphanDetails = @($Orphans | ForEach-Object {
            Get-Process -Id $_ -ErrorAction SilentlyContinue | Select-Object Id, ProcessName
        })
        Write-Warning ("Owned descendants still alive after 10 seconds: " + ($OrphanDetails | ConvertTo-Json -Compress))
        foreach ($Id in $Orphans) { Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue }
        throw "$Kind launch left an owned descendant running: $($Orphans -join ', ')."
    }
    return [ordered]@{
        kind = $Kind
        desktopPid = $Process.Id
        ownedPids = @($Owned | Sort-Object)
        exitCode = $Process.ExitCode
        orphanCount = 0
    }
}

function Assert-Checkpoint([string]$CheckpointPath) {
    Write-LifecycleTransition -Recorder $LifecycleRecorder -State "frontend-checkpoint-read" -Details @{ path = (Split-Path -Leaf $CheckpointPath) }
    $Checkpoint = Get-Content -LiteralPath $CheckpointPath -Raw | ConvertFrom-Json
    if ($Checkpoint.status -ne "complete" -or -not $Checkpoint.qaMode) {
        throw "The frontend QA checkpoint is incomplete."
    }
    $Required = @(
        "overviewRendered", "qaIndicatorRendered", "frontendConnected",
        "projectListLoaded", "projectDetailsLoaded", "settingsLoaded",
        "activityLoaded", "refreshCompleted", "qaIsolationConfirmed",
        "diagnosticsLoaded", "resetCompleted", "regenerationCompleted"
    )
    foreach ($Name in $Required) {
        $Property = $Checkpoint.checks.PSObject.Properties[$Name]
        if ($null -eq $Property -or $Property.Value -ne $true) {
            throw "Frontend checkpoint failed: $Name"
        }
    }
    $AutomationError = $Checkpoint.checks.PSObject.Properties["automationError"]
    if ($null -ne $AutomationError) {
        throw "Frontend automation reported an error: $($AutomationError.Value)"
    }
    if (-not $Checkpoint.sidecarPid) { throw "The checkpoint did not record the owned sidecar PID." }
    $Sidecar = Get-CimInstance Win32_Process -Filter "ProcessId = $($Checkpoint.sidecarPid)" -ErrorAction Stop
    if ($null -eq $Sidecar -or [int]$Sidecar.ParentProcessId -ne [int]$Checkpoint.desktopPid) {
        throw "The recorded sidecar is not owned by the DevPulse desktop process."
    }
    $SidecarProcess = Get-Process -Id $Checkpoint.sidecarPid -ErrorAction Stop
    if ($SidecarProcess.MainWindowHandle -ne [IntPtr]::Zero) {
        throw "The packaged sidecar unexpectedly created a visible console or application window."
    }
    Write-LifecycleTransition -Recorder $LifecycleRecorder -State "authenticated-readiness-confirmed" -DesktopPid ([int]$Checkpoint.desktopPid) -OwnedPids @([int]$Checkpoint.sidecarPid)
    return $Checkpoint
}

$Executable = Find-ReleaseExecutable
$ProductionBefore = Get-ProductionSnapshot
$ProtectedBefore = Get-ProtectedSentinelSnapshot
$GitBefore = (& git status --porcelain=v1 --untracked-files=all) -join "`n"
$PythonExecutable = Join-Path $Root ".venv\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $PythonExecutable -PathType Leaf)) {
    throw "The controlled Python sentinel executable is unavailable."
}
$PythonSentinel = Start-Process -FilePath $PythonExecutable `
    -ArgumentList '-c "import time; time.sleep(300)"' -WindowStyle Hidden -PassThru
$ImmediateResults = @()
$NormalResults = @()
$CheckpointPath = Join-Path $QaRoot "qa-frontend-checkpoint.json"
$FailurePath = Join-Path $QaRoot "qa-startup-failure.json"
$AutomationChecks = $null
$FailureResult = $null
$RecoveryIntegration = $null
$DuplicateResult = $null
$InvalidRecovery = $false
$QaRunCompleted = $false

try {
    Remove-Item -LiteralPath $CheckpointPath -Force -ErrorAction SilentlyContinue
    $Process = Start-DevPulseQa $Executable $true $false
    if (-not (Wait-ForWindow $Process 15)) { throw "Normal launch did not create a native window." }
    if (-not (Wait-ForFile $CheckpointPath 120)) { throw "Frontend automation checkpoint timed out." }
    $AutomationChecks = Assert-Checkpoint $CheckpointPath
    $NormalResults += Stop-OwnedLaunch $Process "normal-1-automation"

    for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
        $Process = Start-DevPulseQa $Executable $false $false
        if (-not (Wait-ForWindow $Process 10)) { throw "Immediate-close attempt $Attempt did not create a window." }
        $ImmediateResults += Stop-OwnedLaunch $Process "immediate-$Attempt"
    }

    # Corrupt only QA-owned data and verify startup regenerates a safe artificial lab.
    Set-Content -LiteralPath (Join-Path $QaRoot "settings.json") -Value "{ invalid qa settings" -Encoding UTF8
    New-Item -ItemType Directory -Force -Path (Join-Path $QaRoot "test-lab") | Out-Null
    Set-Content -LiteralPath (Join-Path $QaRoot "test-lab\qa-manifest.json") -Value "[]" -Encoding UTF8
    New-Item -ItemType Directory -Force -Path (Join-Path $QaRoot "cache") | Out-Null
    Set-Content -LiteralPath (Join-Path $QaRoot "cache\repositories-v1.json") -Value "not-json" -Encoding UTF8
    Remove-Item -LiteralPath $CheckpointPath -Force -ErrorAction SilentlyContinue
    $Process = Start-DevPulseQa $Executable $true $false
    if (-not (Wait-ForWindow $Process 15)) { throw "Invalid-data recovery did not create a window." }
    if (-not (Wait-ForFile $CheckpointPath 120)) { throw "Invalid-data recovery checkpoint timed out." }
    [void](Assert-Checkpoint $CheckpointPath)
    $RecoveredSettings = Get-Content -LiteralPath (Join-Path $QaRoot "settings.json") -Raw | ConvertFrom-Json
    $RecoveredManifest = Get-Content -LiteralPath (Join-Path $QaRoot "test-lab\qa-manifest.json") -Raw | ConvertFrom-Json
    $InvalidRecovery = $RecoveredSettings.schema_version -eq 5 -and $RecoveredManifest.artificial -eq $true
    if (-not $InvalidRecovery) { throw "Invalid QA data was not safely recovered." }
    $NormalResults += Stop-OwnedLaunch $Process "normal-2-invalid-data-recovery"

    $Process = Start-DevPulseQa $Executable $false $false
    if (-not (Wait-ForWindow $Process 15)) { throw "Third normal launch did not create a window." }
    Start-Sleep -Seconds 4
    $NormalResults += Stop-OwnedLaunch $Process "normal-3"

    # Exercise migration, artificial scanner failures, and a real owned-child exit in one
    # isolated lifecycle. Recovery must produce a second authenticated ready state exactly once.
    $LifecyclePath = Join-Path $QaRoot "lifecycle-state.jsonl"
    $MigrationBackup = Join-Path $QaRoot "settings.pre-migration-v4.json"
    Remove-Item -LiteralPath $LifecyclePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $MigrationBackup -Force -ErrorAction SilentlyContinue
    @{ schema_version = 4; onboarding_completed = $true } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $QaRoot "settings.json") -Encoding UTF8
    $Process = Start-DevPulseQa $Executable $false $false $true
    if (-not (Wait-ForWindow $Process 15)) { throw "Recovery integration did not create a native window." }
    $RecoveryEvents = Wait-ForRecoveryEvidence $LifecyclePath 45
    if (-not (Test-Path -LiteralPath $MigrationBackup -PathType Leaf)) {
        throw "Recovery integration did not preserve the schema-4 migration source."
    }
    $IntegratedSettings = Get-Content -LiteralPath (Join-Path $QaRoot "settings.json") -Raw | ConvertFrom-Json
    if ($IntegratedSettings.schema_version -ne 5) {
        throw "Recovery integration did not commit schema 5 before sidecar recovery."
    }
    $RecoveryIntegration = [ordered]@{
        migrationSourcePreserved = $true
        migratedSchema = 5
        artificialScannerFixtures = $true
        events = $RecoveryEvents
        close = Stop-OwnedLaunch $Process "migration-scanner-sidecar-recovery"
    }

    # A second desktop process must exit without creating another sidecar.
    $Primary = Start-DevPulseQa $Executable $false $false
    if (-not (Wait-ForWindow $Primary 15)) { throw "Duplicate-launch primary did not create a window." }
    Start-Sleep -Seconds 2
    $PrimaryOwned = [System.Collections.Generic.HashSet[int]]::new()
    [void](Register-LifecycleProcessIdentity $Script:ReleaseQaProcessIdentities $Primary.Id)
    [void]$PrimaryOwned.Add($Primary.Id)
    Expand-OwnedProcessIds $PrimaryOwned
    $Secondary = Start-DevPulseQa $Executable $false $false
    if (-not $Secondary.WaitForExit(10000)) {
        Stop-Process -Id $Secondary.Id -Force -ErrorAction SilentlyContinue
        throw "Duplicate desktop process did not exit promptly."
    }
    $SecondaryChildren = @(Get-ChildProcessIds $Secondary.Id)
    if ($SecondaryChildren.Count -ne 0) { throw "Duplicate launch created an uncontrolled child process." }
    $DuplicateResult = [ordered]@{
        primaryPid = $Primary.Id
        secondaryPid = $Secondary.Id
        secondaryExitCode = $Secondary.ExitCode
        secondaryChildCount = 0
    }
    [void](Stop-OwnedLaunch $Primary "duplicate-primary")

    Remove-Item -LiteralPath $FailurePath -Force -ErrorAction SilentlyContinue
    $Process = Start-DevPulseQa $Executable $false $true
    if (-not (Wait-ForWindow $Process 15)) { throw "Failure simulation did not create a window." }
    if (-not (Wait-ForFile $FailurePath 30)) { throw "Local-core failure marker timed out." }
    $FailureMarker = Get-Content -LiteralPath $FailurePath -Raw | ConvertFrom-Json
    if ($FailureMarker.status -ne "error") { throw "Local-core failure was not surfaced safely." }
    $FailureResult = [ordered]@{ code = $FailureMarker.code; close = Stop-OwnedLaunch $Process "local-core-failure" }
    $QaRunCompleted = $true
}
finally {
    # Emergency cleanup remains restricted to exact PIDs created by this harness.
    Write-LifecycleTransition -Recorder $LifecycleRecorder -State "cleanup-entered"
    foreach ($VariableName in @("Process", "Primary", "Secondary")) {
        $Value = Get-Variable -Name $VariableName -ValueOnly -ErrorAction SilentlyContinue
        if ($Value -is [System.Diagnostics.Process] -and -not $Value.HasExited) {
            Stop-Process -Id $Value.Id -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $QaRunCompleted -and -not $PythonSentinel.HasExited) {
        Stop-Process -Id $PythonSentinel.Id -Force -ErrorAction SilentlyContinue
    }
}

$ProductionAfter = Get-ProductionSnapshot
$ProtectedAfter = Get-ProtectedSentinelSnapshot
$GitAfter = (& git status --porcelain=v1 --untracked-files=all) -join "`n"
$ProductionUnchanged = (Convert-SnapshotToStableJson $ProductionBefore) -eq (Convert-SnapshotToStableJson $ProductionAfter)
$ProtectedUnchanged = (Convert-SnapshotToStableJson $ProtectedBefore) -eq (Convert-SnapshotToStableJson $ProtectedAfter)
$WorkspaceSourceUnchanged = $GitBefore -eq $GitAfter
$UnrelatedPythonPreserved = -not $PythonSentinel.HasExited
if (-not $PythonSentinel.HasExited) {
    Stop-Process -Id $PythonSentinel.Id -Force -ErrorAction Stop
    $PythonSentinel.WaitForExit()
}
if (-not $ProductionUnchanged) { throw "Production DevPulse application data changed during QA." }
if (-not $ProtectedUnchanged) { throw "A protected sentinel directory's metadata changed during QA." }
if (-not $WorkspaceSourceUnchanged) { throw "Release QA unexpectedly changed workspace source state." }
if (-not $UnrelatedPythonPreserved) { throw "An unrelated Python process disappeared during release QA." }

$Report = [ordered]@{
    schemaVersion = 1
    completedUtc = [DateTime]::UtcNow.ToString("o")
    releaseExecutable = $Executable
    qaRoot = $QaRoot
    installerExecuted = $false
    artificialRepositoriesOnly = $true
    authenticatedHealth = "verified by the desktop ready gate before frontend automation"
    immediateClose = $ImmediateResults
    normalClose = $NormalResults
    automationChecks = $AutomationChecks.checks
    resetRegeneration = $AutomationChecks.checks.refreshCompleted -eq $true
    invalidDataRecovery = $InvalidRecovery
    migrationScannerSidecarRecovery = $RecoveryIntegration
    localCoreFailure = $FailureResult
    duplicateLaunch = $DuplicateResult
    filesystemAudit = [ordered]@{
        productionDataUnchanged = $ProductionUnchanged
        protectedSentinelMetadataUnchanged = $ProtectedUnchanged
        workspaceSourceStateUnchanged = $WorkspaceSourceUnchanged
        approvedWriteRoot = $QaRoot
    }
    processAudit = [ordered]@{
        allOwnedDescendantsExited = $true
        unrelatedPythonProcessesPreserved = $UnrelatedPythonPreserved
        globalNameTerminationUsed = $false
        consoleWindowCreatedBySidecar = $false
    }
    lifecycleEvidence = "lifecycle-timeline.jsonl"
}
$Report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
Complete-LifecycleRecorder -Recorder $LifecycleRecorder -Result "passed" -Summary @{ report = (Split-Path -Leaf $ReportPath); immediateCloseCount = $ImmediateResults.Count; normalCloseCount = $NormalResults.Count }
Write-Host "Release QA passed: $ReportPath"
Write-Host "Release executable: $Executable"
