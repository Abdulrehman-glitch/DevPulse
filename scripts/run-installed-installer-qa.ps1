param(
    [Parameter(Mandatory = $true)][string]$ArtifactDirectory,
    [Parameter(Mandatory = $true)][string]$ReportDirectory
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (
    $env:GITHUB_ACTIONS -ne "true" -or
    $env:RUNNER_ENVIRONMENT -ne "github-hosted" -or
    $env:DEVPULSE_DISPOSABLE_RUNNER -ne "github-hosted"
) {
    throw "Installer execution is restricted to the repository's GitHub-hosted disposable runner job."
}
if ($env:RUNNER_OS -ne "Windows") { throw "Installer QA requires a GitHub-hosted Windows runner." }

. (Join-Path $PSScriptRoot "lib\uninstall-entry-filter.ps1")
. (Join-Path $PSScriptRoot "lib\lifecycle-harness.ps1")

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DevPulseInstalledQaNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out Rect rect);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr handle);
}
"@

$Version = "0.3.0-alpha.1"
$ExpectedInstallDirectory = Join-Path $env:LOCALAPPDATA "DevPulse"
$ExpectedStartMenuDirectory = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\DevPulse"
$ExpectedDesktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "DevPulse.lnk"
$QaRoot = Join-Path $env:RUNNER_TEMP "DevPulse-QA-installed"
$QaRoamingAppData = Join-Path $QaRoot "process-env\roaming"
$QaLocalAppData = Join-Path $QaRoot "process-env\local"
$QaWebView2Data = Join-Path $QaRoot "webview2"
$InvalidTraversalTarget = Join-Path $env:RUNNER_TEMP "DevPulse-QA-invalid-escape"
$ProductionDataPaths = @(
    (Join-Path $env:APPDATA "com.devpulse.desktop"),
    (Join-Path $env:APPDATA "DevPulse"),
    (Join-Path $env:LOCALAPPDATA "com.devpulse.desktop")
) | Select-Object -Unique
$ProtectedDevPulsePaths = @(
    (Join-Path $env:ProgramFiles "DevPulse"),
    $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} "DevPulse" }),
    (Join-Path $env:ProgramData "DevPulse")
) | Where-Object { $_ } | Select-Object -Unique
$ManifestPath = Join-Path $ArtifactDirectory "build-manifest.json"
$InspectionPath = Join-Path $ArtifactDirectory "installer-inspection.json"
New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null
$CommitForEvidence = if ([string]::IsNullOrWhiteSpace($env:DEVPULSE_TESTED_SHA)) { "unknown" } else { $env:DEVPULSE_TESTED_SHA }
$LifecycleRecorder = New-LifecycleRecorder -Directory $ReportDirectory -Scenario "installed-lifecycle-qa" -Version $Version -CommitSha $CommitForEvidence

$Script:OwnedPids = [System.Collections.Generic.HashSet[int]]::new()
$Script:SmokeResults = @()
$Script:ProcessResults = @()
$Script:UninstallResults = @()
$Script:FailureMessage = $null
$Script:CurrentPhase = "initialization"
$Script:EvidenceTimelinePath = Join-Path $ReportDirectory "evidence-timeline.jsonl"
$Script:EvidenceStateSequence = 0
$Script:AppDataSnapshots = @()
$Script:AppDataEvents = @()
$Script:AppDataFirstObserved = @{}
$Script:AppDataWatcherIds = @()
$Script:AppDataWatchers = @()
$Script:ScreenshotRecords = @()
$Script:ProcessCatalog = @{}
$Script:ProcessIdentities = @{}
$Script:EvidenceStartedUtc = [DateTime]::UtcNow
$Manifest = $null
$Sentinel = $null

function ConvertTo-SafePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $Safe = $Path
    foreach ($Replacement in @(
        [pscustomobject]@{ source = $env:GITHUB_WORKSPACE; target = "%GITHUB_WORKSPACE%" },
        [pscustomobject]@{ source = $env:RUNNER_TEMP; target = "%RUNNER_TEMP%" },
        [pscustomobject]@{ source = $env:LOCALAPPDATA; target = "%LOCALAPPDATA%" },
        [pscustomobject]@{ source = $env:APPDATA; target = "%APPDATA%" },
        [pscustomobject]@{ source = $env:USERPROFILE; target = "%USERPROFILE%" }
    )) {
        if ($Replacement.source) { $Safe = $Safe.Replace([string]$Replacement.source, [string]$Replacement.target) }
    }
    return $Safe
}

function ConvertTo-SafeText([string]$Text) {
    if ($null -eq $Text) { return "" }
    $Safe = ConvertTo-SafePath $Text
    $Safe = $Safe -replace '(?i)(X-DevPulse-Token|Authorization|token|password|secret)\s*[:=]\s*[^\s,;]+', '$1=[REDACTED]'
    $Safe = $Safe -replace '(?i)https?://[^\s/@:]+:[^\s/@]+@', 'https://[REDACTED]@'
    $Safe = $Safe -replace '(?i)gh[pousr]_[A-Za-z0-9_]{20,}', '[REDACTED_GITHUB_TOKEN]'
    return $Safe
}

function Write-SafeJson([string]$Name, $Value) {
    $Json = $Value | ConvertTo-Json -Depth 16
    $Safe = ConvertTo-SafeText $Json
    Set-Content -LiteralPath (Join-Path $ReportDirectory $Name) -Value $Safe -Encoding UTF8
}

function Write-EvidenceEvent(
    [string]$Event,
    [ValidateSet("info", "passed", "failed", "unavailable")][string]$Result = "info",
    $Details = $null,
    [int[]]$ProcessIds = @(),
    [string[]]$SafePathIdentifiers = @()
) {
    $Entry = [ordered]@{
        timestamp = [DateTime]::UtcNow.ToString("o")
        stage = $Script:CurrentPhase
        event = $Event
        result = $Result
        processIds = @($ProcessIds | Sort-Object -Unique)
        safePathIdentifiers = @($SafePathIdentifiers | Sort-Object -Unique)
        details = $Details
    }
    $Json = ConvertTo-SafeText ($Entry | ConvertTo-Json -Depth 12 -Compress)
    Add-Content -LiteralPath $Script:EvidenceTimelinePath -Value $Json -Encoding UTF8
}

function Set-EvidenceStage([string]$Stage, [string]$Event = "stage-transition") {
    Sync-AppDataEvidence
    $Script:CurrentPhase = $Stage
    Write-EvidenceEvent -Event $Event -Details ([ordered]@{ stage = $Stage })
    [void](Capture-AppDataStage $Stage)
}

function Register-ProcessEvidence([int]$Id) {
    if ($Id -le 0) { return }
    [void]$Script:OwnedPids.Add($Id)
    $Snapshot = Get-LifecycleProcessSnapshot $Id
    [void](Register-LifecycleProcessIdentity $Script:ProcessIdentities $Id)
    if ($null -ne $Snapshot -and -not $Script:ProcessCatalog.ContainsKey([string]$Id)) {
        $Script:ProcessCatalog[[string]$Id] = [ordered]@{
            processId = $Snapshot.processId
            parentProcessId = $Snapshot.parentProcessId
            name = $Snapshot.name
            executablePath = $Snapshot.executablePath
            creationUtc = $Snapshot.creationUtc
            firstObservedUtc = [DateTime]::UtcNow.ToString("o")
        }
    }
}

function Get-OwnedProcessEvidence {
    $Processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $Result = @()
    foreach ($Id in @($Script:OwnedPids | Sort-Object)) {
        if (-not (Test-LifecycleProcessIdentity $Script:ProcessIdentities $Id)) { continue }
        $Process = $Processes | Where-Object { [int]$_.ProcessId -eq $Id } | Select-Object -First 1
        if ($null -ne $Process) {
            $Result += [ordered]@{
                processId = [int]$Process.ProcessId
                parentProcessId = [int]$Process.ParentProcessId
                name = [string]$Process.Name
                running = $true
            }
        }
    }
    return $Result
}

function Get-TopLevelPathEvidence([string]$Path) {
    $Root = Get-PathState $Path
    if (-not $Root.exists -or -not $Root.directory) { return [ordered]@{ root = $Root; topLevelEntries = @() } }
    $Entries = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $Hash = $null
        if (-not $_.PSIsContainer -and $_.Length -le 10MB) {
            $Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        }
        [ordered]@{
            name = ConvertTo-SafeText $_.Name
            directory = $_.PSIsContainer
            length = if ($_.PSIsContainer) { $null } else { $_.Length }
            creationUtc = $_.CreationTimeUtc.ToString("o")
            lastWriteUtc = $_.LastWriteTimeUtc.ToString("o")
            sha256 = $Hash
        }
    })
    return [ordered]@{ root = $Root; topLevelEntries = $Entries }
}

function Capture-AppDataStage([string]$Stage) {
    $Snapshot = [ordered]@{
        timestamp = [DateTime]::UtcNow.ToString("o")
        stage = $Stage
        paths = @($ProductionDataPaths | ForEach-Object { Get-TopLevelPathEvidence $_ })
        activeOwnedProcesses = @(Get-OwnedProcessEvidence)
    }
    $Script:AppDataSnapshots += $Snapshot
    foreach ($PathState in $Snapshot.paths) {
        if ($PathState.root.exists -and -not $Script:AppDataFirstObserved.ContainsKey($PathState.root.path)) {
            $Script:AppDataFirstObserved[$PathState.root.path] = [ordered]@{
                timestamp = $Snapshot.timestamp
                stage = $Stage
                activeOwnedProcesses = $Snapshot.activeOwnedProcesses
                pathState = $PathState
            }
            Write-EvidenceEvent -Event "protected-appdata-first-observed" -Result failed `
                -Details $Script:AppDataFirstObserved[$PathState.root.path] `
                -ProcessIds @($Snapshot.activeOwnedProcesses | ForEach-Object { $_.processId }) `
                -SafePathIdentifiers @($PathState.root.path)
        }
    }
    return $Snapshot
}

function Start-AppDataWatchers {
    $Definitions = @(
        [ordered]@{ parent = $env:APPDATA; leaf = "com.devpulse.desktop"; id = "roaming-identifier" },
        [ordered]@{ parent = $env:APPDATA; leaf = "DevPulse"; id = "roaming-product" },
        [ordered]@{ parent = $env:LOCALAPPDATA; leaf = "com.devpulse.desktop"; id = "local-identifier" }
    )
    foreach ($Definition in $Definitions) {
        $Watcher = [System.IO.FileSystemWatcher]::new($Definition.parent, $Definition.leaf)
        $Watcher.IncludeSubdirectories = $true
        $Watcher.NotifyFilter = [System.IO.NotifyFilters]::DirectoryName -bor
            [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::CreationTime -bor
            [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::Size
        foreach ($EventName in @("Created", "Changed", "Deleted", "Renamed")) {
            $Identifier = "DevPulse-AppData-$($Definition.id)-$EventName"
            [void](Register-ObjectEvent -InputObject $Watcher -EventName $EventName -SourceIdentifier $Identifier)
            $Script:AppDataWatcherIds += $Identifier
        }
        $Watcher.EnableRaisingEvents = $true
        if ($null -eq $Script:AppDataWatchers) { $Script:AppDataWatchers = @() }
        $Script:AppDataWatchers += $Watcher
    }
    Write-EvidenceEvent -Event "protected-appdata-watchers-started" -Details ([ordered]@{
        scope = "three exact DevPulse-related paths only"
        watcherCount = $Definitions.Count
    })
}

function Sync-AppDataEvidence {
    $HadAllowedEvent = $false
    foreach ($Identifier in @($Script:AppDataWatcherIds)) {
        foreach ($Queued in @(Get-Event -SourceIdentifier $Identifier -ErrorAction SilentlyContinue)) {
            $Args = $Queued.SourceEventArgs
            $FullPath = if ($null -ne $Args) { [string]$Args.FullPath } else { "" }
            $Allowed = @($ProductionDataPaths | Where-Object {
                $FullPath -eq $_ -or $FullPath.StartsWith("$_\", [System.StringComparison]::OrdinalIgnoreCase)
            })
            if ($Allowed.Count -gt 0) {
                $HadAllowedEvent = $true
                $Owned = @(Get-OwnedProcessEvidence)
                $Record = [ordered]@{
                    timestamp = $Queued.TimeGenerated.ToUniversalTime().ToString("o")
                    observedUtc = [DateTime]::UtcNow.ToString("o")
                    stage = $Script:CurrentPhase
                    changeType = [string]$Args.ChangeType
                    path = ConvertTo-SafePath $FullPath
                    activeOwnedProcesses = $Owned
                }
                $Script:AppDataEvents += $Record
                Write-EvidenceEvent -Event "protected-appdata-filesystem-event" -Result failed `
                    -Details $Record -ProcessIds @($Owned | ForEach-Object { $_.processId }) `
                    -SafePathIdentifiers @($Record.path)
            }
            Remove-Event -EventIdentifier $Queued.EventIdentifier -ErrorAction SilentlyContinue
        }
    }
    if ($HadAllowedEvent) { [void](Capture-AppDataStage $Script:CurrentPhase) }
}

function Stop-AppDataWatchers {
    Sync-AppDataEvidence
    [void](Capture-AppDataStage $Script:CurrentPhase)
    foreach ($Identifier in @($Script:AppDataWatcherIds)) {
        Unregister-Event -SourceIdentifier $Identifier -ErrorAction SilentlyContinue
        Get-Event -SourceIdentifier $Identifier -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
    }
    foreach ($Watcher in @($Script:AppDataWatchers)) { $Watcher.Dispose() }
    Write-SafeJson "appdata-write-timeline.json" ([ordered]@{
        schemaVersion = 1
        protectedPaths = @($ProductionDataPaths | ForEach-Object { ConvertTo-SafePath $_ })
        scope = "exact DevPulse-related paths only"
        snapshots = $Script:AppDataSnapshots
        filesystemEvents = $Script:AppDataEvents
        firstObserved = @($Script:AppDataFirstObserved.Values)
    })
}

function Save-EvidenceState([string]$Name, [string]$Result = "info") {
    Sync-AppDataEvidence
    [void](Capture-AppDataStage $Script:CurrentPhase)
    $Script:EvidenceStateSequence += 1
    $FileName = "state-{0:D3}-{1}.json" -f $Script:EvidenceStateSequence, ($Name -replace '[^a-z0-9-]', '-')
    $Owned = @(Get-OwnedProcessEvidence)
    $OwnedIds = @($Owned | ForEach-Object { $_.processId })
    $Listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object {
        $_.OwningProcess -in $OwnedIds -and $_.LocalAddress -in @("127.0.0.1", "::1")
    } | ForEach-Object {
        [ordered]@{ processId = $_.OwningProcess; address = $_.LocalAddress; port = $_.LocalPort }
    })
    $Payload = [ordered]@{
        schemaVersion = 1
        timestamp = [DateTime]::UtcNow.ToString("o")
        stage = $Script:CurrentPhase
        event = $Name
        result = $Result
        exactState = Get-ExactState
        qaRoot = Get-PathState $QaRoot
        ownedProcesses = $Owned
        ownedProcessCatalog = @($Script:ProcessCatalog.Values)
        localhostListeners = $Listeners
    }
    Write-SafeJson $FileName $Payload
    Write-EvidenceEvent -Event $Name -Result $Result -Details ([ordered]@{ evidenceFile = $FileName }) -ProcessIds $OwnedIds
    return $FileName
}

function Add-ScreenshotEvidence([string]$Stage, [string]$Status, [string]$File, [string]$Reason) {
    $Existing = @($Script:ScreenshotRecords | Where-Object { $_.stage -eq $Stage })
    if ($Existing.Count -gt 0) { return }
    $Script:ScreenshotRecords += [ordered]@{
        timestamp = [DateTime]::UtcNow.ToString("o")
        stage = $Stage
        status = $Status
        file = $File
        reason = ConvertTo-SafeText $Reason
    }
    Write-EvidenceEvent -Event "screenshot-$Stage" `
        -Result $(if ($Status -eq "captured") { "passed" } else { "unavailable" }) `
        -Details ([ordered]@{ status = $Status; file = $File; reason = $Reason })
}

function Save-StageScreenshot(
    [string]$Stage,
    [AllowNull()][System.Diagnostics.Process]$Process = $null,
    [switch]$SilentProcessExpected
) {
    if ($SilentProcessExpected) {
        Add-ScreenshotEvidence $Stage "unavailable" $null "Silent NSIS mode exposed no installer window; no screenshot was fabricated."
        return
    }
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $Bounds = $null
        if ($null -ne $Process) {
            if ($Process.HasExited) { throw "The target process exited before capture." }
            $Process.Refresh()
            if ($Process.MainWindowHandle -eq [IntPtr]::Zero) { throw "The target process has no usable interactive window." }
            [void][DevPulseInstalledQaNative]::SetForegroundWindow($Process.MainWindowHandle)
            Start-Sleep -Milliseconds 250
            $Rect = [DevPulseInstalledQaNative+Rect]::new()
            if (-not [DevPulseInstalledQaNative]::GetWindowRect($Process.MainWindowHandle, [ref]$Rect)) {
                throw "The target window bounds were unavailable."
            }
            $Bounds = [System.Drawing.Rectangle]::FromLTRB($Rect.Left, $Rect.Top, $Rect.Right, $Rect.Bottom)
        } else {
            $Bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        }
        if ($Bounds.Width -lt 64 -or $Bounds.Height -lt 64) { throw "The interactive desktop bounds were unusable." }
        $Directory = Join-Path $ReportDirectory "screenshots"
        New-Item -ItemType Directory -Force -Path $Directory | Out-Null
        $Stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ")
        $Slug = $Stage -replace '[^a-z0-9-]', '-'
        $FileName = "$Stamp-$Slug.png"
        $Destination = Join-Path $Directory $FileName
        $Bitmap = [System.Drawing.Bitmap]::new($Bounds.Width, $Bounds.Height)
        $Graphics = [System.Drawing.Graphics]::FromImage($Bitmap)
        try {
            $Graphics.CopyFromScreen($Bounds.Left, $Bounds.Top, 0, 0, $Bitmap.Size)
            $Bitmap.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $Graphics.Dispose()
            $Bitmap.Dispose()
        }
        if ((Get-Item -LiteralPath $Destination).Length -lt 128) {
            Remove-Item -LiteralPath $Destination -Force
            throw "The captured image was empty."
        }
        Add-ScreenshotEvidence $Stage "captured" "screenshots/$FileName" "Captured from the disposable runner's interactive session."
    }
    catch {
        Add-ScreenshotEvidence $Stage "unavailable" $null $_.Exception.Message
    }
}

function Complete-VisualEvidenceIndex {
    $Stages = @(
        "pre-install-desktop", "installer-launch", "installation-completed",
        "installed-startup", "qa-mode-banner", "overview-page", "projects-page",
        "project-details-page", "activity-page", "settings-page", "diagnostics-page",
        "failure-recovery", "before-uninstall", "after-uninstall", "reinstalled-application",
        "final-clean-state"
    )
    foreach ($Stage in $Stages) {
        if (@($Script:ScreenshotRecords | Where-Object { $_.stage -eq $Stage }).Count -eq 0) {
            Add-ScreenshotEvidence $Stage "not-reached" $null "The lifecycle did not reach this capture point."
        }
    }
    $Captured = @($Script:ScreenshotRecords | Where-Object { $_.status -eq "captured" })
    $TimeLapse = if ($Captured.Count -ge 3) {
        [ordered]@{
            status = "captured"
            format = "timestamped PNG sequence"
            frameCount = $Captured.Count
            note = "Repository-owned screenshot capture supplied the bounded time-lapse sequence; no external recorder was downloaded."
        }
    } else {
        [ordered]@{
            status = "unsupported"
            format = $null
            frameCount = $Captured.Count
            note = "The runner did not expose enough usable interactive frames; lifecycle assertions continued."
        }
    }
    Write-SafeJson "screenshot-index.json" ([ordered]@{
        schemaVersion = 1
        screenshots = $Script:ScreenshotRecords
        timeLapse = $TimeLapse
    })
}

function Write-FinalEvidenceReports([string]$Status) {
    $InstallerName = if ($null -ne $Manifest) { $Manifest.installerFilename } else { "unavailable" }
    $InstallerSize = if ($null -ne $Manifest) { $Manifest.installerByteSize } else { "unavailable" }
    $InstallerHash = if ($null -ne $Manifest) { $Manifest.installerSha256 } else { "unavailable" }
    $RunnerImage = if ($env:ImageOS -or $env:ImageVersion) { "$env:ImageOS $env:ImageVersion".Trim() } else { "GitHub-hosted Windows (details unavailable)" }
    $AppDataStatus = if ($Script:AppDataFirstObserved.Count -eq 0) { "passed; no protected path appeared" } else { "failed; see appdata-write-timeline.json" }
    $CapturedScreenshots = @($Script:ScreenshotRecords | Where-Object { $_.status -eq "captured" }).Count
    $EvidenceFiles = @(Get-ChildItem -LiteralPath $ReportDirectory -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($ReportDirectory.Length).TrimStart('\').Replace('\', '/')
    })
    $Links = @($EvidenceFiles | ForEach-Object { "- [$($_)]($($_ -replace ' ', '%20'))" }) -join "`n"
    $Summary = @"
# DevPulse remote installer QA evidence

- Workflow run ID: $env:GITHUB_RUN_ID
- Commit SHA: $env:DEVPULSE_TESTED_SHA
- DevPulse version: $Version
- Runner: $RunnerImage; GitHub-hosted disposable Windows runner
- Installer: $InstallerName
- Installer byte size: $InstallerSize
- Installer SHA-256: $InstallerHash
- Signing: unsigned
- Evidence capture started: $($Script:EvidenceStartedUtc.ToString("o"))
- Build artifact verification: $(if ($null -ne $Manifest) { "passed" } else { "not completed" })
- Installation lifecycle result: $Status
- Authenticated readiness launches: $($Script:SmokeResults.Count)
- Immediate-close launches: $(@($Script:ProcessResults | Where-Object { $_.kind -like 'immediate-close-*' }).Count)
- Process ownership observations: $($Script:ProcessResults.Count)
- Uninstall cycles: $($Script:UninstallResults.Count)
- Production AppData isolation: $AppDataStatus
- Screenshot files captured: $CapturedScreenshots
- Failure phase: $(if ($Script:FailureMessage) { $Script:CurrentPhase } else { "none" })
- Safe failure: $(if ($Script:FailureMessage) { $Script:FailureMessage } else { "none" })
- Known limitations: unsigned alpha; GitHub-hosted Windows accounts are administrative, so non-elevation evidence combines asInvoker/current-user configuration with absence of machine writes; WebView2 mode is skip and requires a preinstalled runtime; silent NSIS mode may expose no installer window; no upgrade or GitHub Release publishing was performed.

## Evidence files

$Links
"@
    Set-Content -LiteralPath (Join-Path $ReportDirectory "final-installer-qa-summary.md") -Value $Summary -Encoding UTF8

    $Rows = @($EvidenceFiles | ForEach-Object {
        $Encoded = [System.Net.WebUtility]::HtmlEncode($_)
        $Href = [System.Uri]::EscapeUriString($_)
        "<li><a href=`"$Href`">$Encoded</a></li>"
    }) -join "`n"
    $SafeFailure = [System.Net.WebUtility]::HtmlEncode($(if ($Script:FailureMessage) { $Script:FailureMessage } else { "none" }))
    $Html = @"
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>DevPulse installer QA evidence</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;max-width:1050px;margin:2rem auto;padding:0 1rem;color:#172033}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ccd4e0;padding:.5rem;text-align:left}th{background:#edf2f7}code{background:#f4f6f8;padding:.1rem .25rem}li{margin:.3rem 0}</style></head>
<body><h1>DevPulse remote installer QA evidence</h1>
<table><tr><th>Run ID</th><td>$([System.Net.WebUtility]::HtmlEncode($env:GITHUB_RUN_ID))</td></tr>
<tr><th>Commit</th><td><code>$([System.Net.WebUtility]::HtmlEncode($env:DEVPULSE_TESTED_SHA))</code></td></tr>
<tr><th>Version</th><td>$Version</td></tr><tr><th>Runner</th><td>$([System.Net.WebUtility]::HtmlEncode($RunnerImage))</td></tr>
<tr><th>Installer</th><td>$([System.Net.WebUtility]::HtmlEncode([string]$InstallerName))</td></tr>
<tr><th>SHA-256</th><td><code>$([System.Net.WebUtility]::HtmlEncode([string]$InstallerHash))</code></td></tr>
<tr><th>Lifecycle</th><td>$Status</td></tr><tr><th>AppData isolation</th><td>$([System.Net.WebUtility]::HtmlEncode($AppDataStatus))</td></tr>
<tr><th>Failure</th><td>$SafeFailure</td></tr></table>
<h2>Evidence files</h2><ul>$Rows</ul>
<p>Known limitations are recorded in <a href="final-installer-qa-summary.md">the Markdown summary</a>.</p></body></html>
"@
    Set-Content -LiteralPath (Join-Path $ReportDirectory "final-installer-qa-evidence.html") -Value $Html -Encoding UTF8
}

function Get-PathState([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return [ordered]@{ path = ConvertTo-SafePath $Path; exists = $false }
    }
    $Item = Get-Item -LiteralPath $Path -Force
    return [ordered]@{
        path = ConvertTo-SafePath $Path
        exists = $true
        directory = $Item.PSIsContainer
        length = if ($Item.PSIsContainer) { $null } else { $Item.Length }
        creationUtc = $Item.CreationTimeUtc.ToString("o")
        lastWriteUtc = $Item.LastWriteTimeUtc.ToString("o")
        attributes = $Item.Attributes.ToString()
    }
}

function Get-UninstallEntries([ValidateSet("CurrentUser", "LocalMachine")][string]$Scope) {
    $Root = if ($Scope -eq "CurrentUser") {
        "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    } else {
        "Registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    }
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -ErrorAction Stop | ForEach-Object {
        $Properties = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
        if (Test-DevPulseUninstallEntry -Properties $Properties) {
            [ordered]@{
                scope = $Scope
                keyName = $_.PSChildName
                displayName = [string]$Properties.PSObject.Properties["DisplayName"].Value
                displayVersion = $Properties.DisplayVersion
                publisher = $Properties.Publisher
                installLocation = ConvertTo-SafePath ([string]$Properties.InstallLocation)
                uninstallString = ConvertTo-SafePath ([string]$Properties.UninstallString)
            }
        }
    })
}

function Get-ExactState {
    $Services = @(Get-Service -ErrorAction Stop | Where-Object {
        $_.Name -eq "DevPulse" -or $_.DisplayName -eq "DevPulse"
    } | ForEach-Object { [ordered]@{ name = $_.Name; displayName = $_.DisplayName; status = [string]$_.Status } })
    $Tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
        $_.TaskName -eq "DevPulse" -or $_.TaskPath -eq "\DevPulse\"
    } | ForEach-Object { [ordered]@{ name = $_.TaskName; path = $_.TaskPath; state = [string]$_.State } })
    $Startup = @()
    foreach ($Key in @(
        "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run",
        "Registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Run"
    )) {
        if (Test-Path -LiteralPath $Key) {
            $Properties = Get-ItemProperty -LiteralPath $Key -Name "DevPulse" -ErrorAction SilentlyContinue
            $Value = if ($null -ne $Properties -and $null -ne $Properties.PSObject.Properties["DevPulse"]) {
                $Properties.PSObject.Properties["DevPulse"].Value
            } else {
                $null
            }
            if ($null -ne $Value) { $Startup += [ordered]@{ key = $Key; name = "DevPulse"; value = ConvertTo-SafePath ([string]$Value) } }
        }
    }
    $Firewall = @(Get-NetFirewallRule -DisplayName "DevPulse" -ErrorAction SilentlyContinue | ForEach-Object {
        [ordered]@{ displayName = $_.DisplayName; direction = [string]$_.Direction; action = [string]$_.Action }
    })
    return [ordered]@{
        expectedInstallDirectory = Get-PathState $ExpectedInstallDirectory
        expectedRoamingData = @($ProductionDataPaths | ForEach-Object { Get-PathState $_ })
        startMenuDirectory = Get-PathState $ExpectedStartMenuDirectory
        desktopShortcut = Get-PathState $ExpectedDesktopShortcut
        currentUserUninstallEntries = @(Get-UninstallEntries "CurrentUser")
        machineUninstallEntries = @(Get-UninstallEntries "LocalMachine")
        services = $Services
        scheduledTasks = $Tasks
        startupEntries = $Startup
        firewallRules = $Firewall
        protectedDevPulsePaths = @($ProtectedDevPulsePaths | ForEach-Object { Get-PathState $_ })
    }
}

function Expand-OwnedPids([System.Collections.Generic.HashSet[int]]$Ids) {
    $Processes = @(Get-LifecycleProcessTable)
    $ProcessMap = @{}
    foreach ($Process in $Processes) { $ProcessMap[[string]$Process.processId] = $Process }
    $Changed = $true
    while ($Changed) {
        $Changed = $false
        foreach ($Candidate in $Processes) {
            $Parent = $ProcessMap[[string]$Candidate.parentProcessId]
            if ((Test-LifecycleChildSnapshotRelationship $Script:ProcessIdentities $Parent $Candidate) -and $Ids.Add([int]$Candidate.processId)) {
                Register-ProcessEvidence ([int]$Candidate.ProcessId)
                $Changed = $true
            }
        }
    }
    foreach ($Id in @($Ids)) { Register-ProcessEvidence $Id }
}

function Test-Alive([int]$Id) {
    return Test-LifecycleProcessIdentity $Script:ProcessIdentities $Id
}

function Stop-RecordedProcesses([System.Collections.Generic.HashSet[int]]$Ids) {
    Expand-OwnedPids $Ids
    foreach ($Id in @($Ids | Sort-Object -Descending)) {
        if (Test-Alive $Id) { Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue }
    }
}

function Test-ProcessInJob([int]$Id) {
    $Handle = [DevPulseInstalledQaNative]::OpenProcess(0x1000, $false, [uint32]$Id)
    if ($Handle -eq [IntPtr]::Zero) { return $false }
    try {
        $Result = $false
        if (-not [DevPulseInstalledQaNative]::IsProcessInJob($Handle, [IntPtr]::Zero, [ref]$Result)) { return $false }
        return $Result
    }
    finally { [void][DevPulseInstalledQaNative]::CloseHandle($Handle) }
}

function Invoke-BoundedExecutable(
    [string]$FilePath,
    [string]$Arguments,
    [string]$Kind,
    [int]$TimeoutSeconds = 180
) {
    $StdoutPath = Join-Path $env:RUNNER_TEMP "DevPulse-QA-$Kind-stdout.tmp"
    $StderrPath = Join-Path $env:RUNNER_TEMP "DevPulse-QA-$Kind-stderr.tmp"
    Remove-Item -LiteralPath $StdoutPath, $StderrPath -Force -ErrorAction SilentlyContinue
    $Info = [System.Diagnostics.ProcessStartInfo]::new()
    $Info.FileName = $FilePath
    $Info.Arguments = $Arguments
    $Info.WorkingDirectory = Split-Path -Parent $FilePath
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    $Process = [System.Diagnostics.Process]::new()
    $Process.StartInfo = $Info
    $Ids = [System.Collections.Generic.HashSet[int]]::new()
    try {
        if (-not $Process.Start()) { throw "$Kind could not be started." }
        Register-ProcessEvidence $Process.Id
        [void]$Ids.Add($Process.Id)
        Write-EvidenceEvent -Event "$Kind-process-started" -Details ([ordered]@{ processId = $Process.Id; arguments = $Arguments }) -ProcessIds @($Process.Id)
        $StdoutTask = $Process.StandardOutput.ReadToEndAsync()
        $StderrTask = $Process.StandardError.ReadToEndAsync()
        $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not $Process.HasExited -and [DateTime]::UtcNow -lt $Deadline) {
            Expand-OwnedPids $Ids
            foreach ($Id in $Ids) { [void]$Script:OwnedPids.Add($Id) }
            Sync-AppDataEvidence
            Start-Sleep -Milliseconds 250
        }
        if (-not $Process.HasExited) {
            Stop-RecordedProcesses $Ids
            throw "$Kind exceeded its bounded $TimeoutSeconds second timeout."
        }
        $Process.WaitForExit()
        # NSIS may leave a short-lived child after its launcher exits. ParentProcessId remains
        # attributable on Windows, so expand once more and wait within the original deadline.
        do {
            Expand-OwnedPids $Ids
            foreach ($Id in $Ids) { [void]$Script:OwnedPids.Add($Id) }
            $Alive = @($Ids | Where-Object { Test-Alive $_ })
            if ($Alive.Count -eq 0) { break }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $Deadline)
        Set-Content -LiteralPath $StdoutPath -Value (ConvertTo-SafeText $StdoutTask.Result) -Encoding UTF8
        Set-Content -LiteralPath $StderrPath -Value (ConvertTo-SafeText $StderrTask.Result) -Encoding UTF8
        Copy-Item -LiteralPath $StdoutPath -Destination (Join-Path $ReportDirectory "$Kind-stdout.log") -Force
        Copy-Item -LiteralPath $StderrPath -Destination (Join-Path $ReportDirectory "$Kind-stderr.log") -Force
        if ($Alive.Count -gt 0) { throw "$Kind left an owned process running: $($Alive -join ', ')." }
        Write-EvidenceEvent -Event "$Kind-process-exited" -Result passed -Details ([ordered]@{ exitCode = $Process.ExitCode }) -ProcessIds @($Ids)
        return [ordered]@{
            kind = $Kind
            arguments = $Arguments
            exitCode = $Process.ExitCode
            timedOut = $false
            requestedRunAs = $false
            ownedPids = @($Ids | Sort-Object)
        }
    }
    finally {
        if ($null -ne $Process -and -not $Process.HasExited) { Stop-RecordedProcesses $Ids }
        Remove-Item -LiteralPath $StdoutPath, $StderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-InstalledExecutable {
    $Candidates = @(Get-ChildItem -LiteralPath $ExpectedInstallDirectory -File -Filter "*.exe" | Where-Object {
        $_.VersionInfo.ProductName -eq "DevPulse" -and $_.Name -notmatch "uninstall"
    })
    if ($Candidates.Count -ne 1) { throw "Expected exactly one installed DevPulse application executable." }
    return $Candidates[0].FullName
}

function Get-InstalledSidecar {
    $Candidates = @(Get-ChildItem -LiteralPath $ExpectedInstallDirectory -Recurse -File -Filter "devpulse-local-core*.exe")
    if ($Candidates.Count -ne 1) { throw "Expected exactly one installed packaged sidecar." }
    return $Candidates[0].FullName
}

function Test-ExpectedInstalledDescendant($Process, [int]$SidecarPid) {
    $Name = [string]$Process.Name
    if ($Name -match "^(devpulse-desktop|devpulse-local-core|msedgewebview2)\.exe$") {
        return $true
    }
    if ($Name -ine "conhost.exe" -or [int]$Process.ParentProcessId -ne $SidecarPid) {
        return $false
    }

    # A console-subsystem PyInstaller sidecar can receive the ordinary Windows console
    # host even when its parent requests a hidden window. Treat only the canonical
    # System32 binary owned directly by the already-verified sidecar as expected.
    $ExpectedConsoleHost = Join-Path $env:SystemRoot "System32\conhost.exe"
    if ([string]::IsNullOrWhiteSpace([string]$Process.ExecutablePath) -or
        -not [string]::Equals(
            [System.IO.Path]::GetFullPath([string]$Process.ExecutablePath),
            [System.IO.Path]::GetFullPath($ExpectedConsoleHost),
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        return $false
    }
    if ([string]$Process.CommandLine -match '(?i)--token(?:\s|=)|--handshake-file(?:\s|=)|X-DevPulse-Token|Authorization') {
        return $false
    }
    return $true
}

function New-InstalledStartInfo([string]$Executable, [hashtable]$Variables) {
    $StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = $Executable
    $StartInfo.WorkingDirectory = $ExpectedInstallDirectory
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    foreach ($Name in @(
        "DEVPULSE_QA_MODE", "DEVPULSE_INSTALL_QA", "DEVPULSE_QA_AUTOMATION",
        "DEVPULSE_QA_ROOT", "DEVPULSE_QA_FAIL_START", "DEVPULSE_DATA_DIR",
        "WEBVIEW2_USER_DATA_FOLDER"
    )) {
        [void]$StartInfo.Environment.Remove($Name)
    }
    foreach ($Name in $Variables.Keys) {
        $StartInfo.Environment[$Name] = [string]$Variables[$Name]
    }
    return $StartInfo
}

function Start-InstalledWithEnvironment([string]$Executable, [hashtable]$Variables) {
    $Process = [System.Diagnostics.Process]::Start((New-InstalledStartInfo $Executable $Variables))
    if ($null -eq $Process) { throw "The installed DevPulse process could not be started." }
    Write-LifecycleTransition -Recorder $LifecycleRecorder -State "native-process-created" -DesktopPid $Process.Id
    return $Process
}

function Start-InstalledQa([string]$Executable, [bool]$Automation, [bool]$FailStart) {
    # Apply environment variables only to the installed child. The installer, uninstaller,
    # evidence harness, and the runner's own per-user paths remain unchanged.
    $Process = Start-InstalledWithEnvironment $Executable @{
        DEVPULSE_QA_MODE = "1"
        DEVPULSE_INSTALL_QA = "1"
        DEVPULSE_QA_AUTOMATION = if ($Automation) { "1" } else { "0" }
        DEVPULSE_QA_ROOT = $QaRoot
        DEVPULSE_QA_FAIL_START = if ($FailStart) { "1" } else { "0" }
        DEVPULSE_DATA_DIR = $QaRoot
        APPDATA = $QaRoamingAppData
        LOCALAPPDATA = $QaLocalAppData
        WEBVIEW2_USER_DATA_FOLDER = $QaWebView2Data
    }
    Register-ProcessEvidence $Process.Id
    Write-EvidenceEvent -Event "installed-application-started" -Details ([ordered]@{
        processId = $Process.Id
        automation = $Automation
        simulatedSidecarFailure = $FailStart
        qaMode = $true
        installQa = $true
        childOnlyEnvironment = $true
    }) -ProcessIds @($Process.Id) -SafePathIdentifiers @("%RUNNER_TEMP%\DevPulse-QA-installed")
    return $Process
}

function Invoke-QaGateRefusalTests([string]$Executable) {
    $Cases = @(
        [ordered]@{ name = "qa-mode-only"; unexpectedPath = $null; variables = @{ DEVPULSE_QA_MODE = "1" } },
        [ordered]@{ name = "install-qa-only"; unexpectedPath = $null; variables = @{ DEVPULSE_INSTALL_QA = "1" } },
        [ordered]@{
            name = "parent-traversal-root"
            unexpectedPath = $InvalidTraversalTarget
            variables = @{
                DEVPULSE_QA_MODE = "1"
                DEVPULSE_QA_ROOT = (Join-Path $QaRoot "..\DevPulse-QA-invalid-escape")
            }
        }
    )
    $Results = @()
    foreach ($Case in $Cases) {
        Set-EvidenceStage "QA gate refusal $($Case.name)"
        $Process = Start-InstalledWithEnvironment $Executable $Case.variables
        try {
            if (-not $Process.WaitForExit(10000)) {
                Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
                throw "Incomplete QA launch $($Case.name) did not refuse within the bounded timeout."
            }
            if ($Process.ExitCode -ne 78) {
                throw "Incomplete QA launch $($Case.name) returned $($Process.ExitCode), expected safe-refusal code 78."
            }
            $Children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($Process.Id)" -ErrorAction SilentlyContinue)
            if ($Children.Count -ne 0) { throw "Incomplete QA launch $($Case.name) created a child process." }
            if ($Case.unexpectedPath -and (Test-Path -LiteralPath $Case.unexpectedPath)) {
                throw "Incomplete QA launch $($Case.name) created its rejected traversal target."
            }
            Assert-ProductionDataClean "QA gate refusal $($Case.name)"
            $Result = [ordered]@{
                name = $Case.name
                processId = $Process.Id
                exitCode = $Process.ExitCode
                childCount = 0
                productionAppDataUntouched = $true
            }
            $Results += $Result
            Write-EvidenceEvent -Event "qa-gate-refused" -Result passed -Details $Result -ProcessIds @($Process.Id)
        }
        finally {
            if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue }
            $Process.Dispose()
        }
    }
    Write-SafeJson "qa-gate-refusal-results.json" ([ordered]@{
        schemaVersion = 1
        status = "passed"
        expectedExitCode = 78
        attempts = $Results
    })
    return $Results
}

function Sync-VisualCheckpoint(
    [AllowNull()][System.Diagnostics.Process]$Process,
    [string]$Kind
) {
    if ($null -eq $Process) { return }
    $MarkerPath = Join-Path $QaRoot "qa-visual-checkpoint.json"
    if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) { return }
    try {
        $Marker = Get-Content -LiteralPath $MarkerPath -Raw | ConvertFrom-Json
        if ([int]$Marker.desktopPid -ne $Process.Id) { throw "Visual checkpoint PID did not match its installed desktop." }
        $Stage = [string]$Marker.stage
        Save-StageScreenshot $Stage $Process
        if ($Kind -eq "reinstall-smoke") { Save-StageScreenshot "reinstalled-application" $Process }
        Write-EvidenceEvent -Event "visual-checkpoint-observed" -Result passed `
            -Details ([ordered]@{ stage = $Stage; launch = $Kind }) -ProcessIds @($Process.Id)
        Remove-Item -LiteralPath $MarkerPath -Force
    }
    catch {
        Write-EvidenceEvent -Event "visual-checkpoint-unavailable" -Result unavailable `
            -Details ([ordered]@{ error = $_.Exception.Message; launch = $Kind }) -ProcessIds @($Process.Id)
        Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
    }
}

function Wait-ForFile(
    [string]$Path,
    [int]$TimeoutSeconds,
    [AllowNull()][System.Diagnostics.Process]$VisualProcess = $null,
    [string]$VisualKind = ""
) {
    $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $Deadline) {
        Sync-VisualCheckpoint $VisualProcess $VisualKind
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return $true }
        Sync-AppDataEvidence
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Stop-InstalledLaunch([System.Diagnostics.Process]$Process, [string]$Kind) {
    $Ids = [System.Collections.Generic.HashSet[int]]::new()
    [void]$Ids.Add($Process.Id)
    Expand-OwnedPids $Ids
    $Process.Refresh()
    if (-not $Process.HasExited) {
        Write-LifecycleTransition -Recorder $LifecycleRecorder -State "close-requested" -DesktopPid $Process.Id -OwnedPids @($Ids) -Details @{ kind = $Kind; windowHandlePresent = $Process.MainWindowHandle -ne [IntPtr]::Zero }
        if ($Process.MainWindowHandle -eq [IntPtr]::Zero -or
            -not [DevPulseInstalledQaNative]::PostMessage($Process.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) {
            throw "$Kind did not expose a closeable native window."
        }
    }
    if (-not $Process.WaitForExit(30000)) {
        Write-LifecycleTransition -Recorder $LifecycleRecorder -State "close-timeout" -DesktopPid $Process.Id -OwnedPids @($Ids) -Details @{ kind = $Kind; timeoutSeconds = 30 }
        Stop-RecordedProcesses $Ids
        throw "$Kind did not close within 30 seconds."
    }
    Sync-AppDataEvidence
    Expand-OwnedPids $Ids
    $Deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $Alive = @($Ids | Where-Object { $_ -ne $Process.Id -and (Test-Alive $_) })
        if ($Alive.Count -eq 0) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $Deadline)
    if ($Alive.Count -gt 0) {
        Stop-RecordedProcesses $Ids
        throw "$Kind left owned descendants running."
    }
    Write-EvidenceEvent -Event "$Kind-normal-close-completed" -Result passed `
        -Details ([ordered]@{ exitCode = $Process.ExitCode; orphanCount = 0 }) -ProcessIds @($Ids)
    Write-LifecycleTransition -Recorder $LifecycleRecorder -State "desktop-process-exited" -DesktopPid $Process.Id -OwnedPids @($Ids) -Details @{ kind = $Kind; exitCode = $Process.ExitCode }
    return [ordered]@{ kind = $Kind; desktopPid = $Process.Id; exitCode = $Process.ExitCode; ownedPids = @($Ids | Sort-Object); orphanCount = 0 }
}

function Invoke-AutomatedSmoke([string]$Executable, [string]$Kind) {
    $ResultPath = Join-Path $QaRoot "installed-smoke-result.json"
    $CheckpointPath = Join-Path $QaRoot "qa-frontend-checkpoint.json"
    $ObservedPath = Join-Path $QaRoot "installed-smoke-observed.json"
    Remove-Item -LiteralPath $ResultPath, $CheckpointPath, $ObservedPath -Force -ErrorAction SilentlyContinue
    $Process = Start-InstalledQa $Executable $true $false
    $Ids = [System.Collections.Generic.HashSet[int]]::new()
    [void]$Ids.Add($Process.Id)
    try {
        if (-not (Wait-ForFile $ResultPath 120 $Process $Kind)) { throw "$Kind readiness result timed out." }
        Set-EvidenceStage "$Kind readiness" "authenticated-readiness-observed"
        $Result = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
        if ($Result.status -ne "passed" -or $Result.exitCode -ne 0 -or -not $Result.installQa) { throw "$Kind reported a failed readiness probe." }
        $Required = @(
            "overviewRendered", "qaIndicatorRendered", "frontendConnected", "projectListLoaded",
            "projectDetailsLoaded", "settingsLoaded", "activityLoaded", "refreshCompleted",
            "qaIsolationConfirmed", "frontendQaPathsReceived", "webViewQaIsolationConfirmed",
            "diagnosticsLoaded", "resetCompleted", "regenerationCompleted"
        )
        foreach ($Name in $Required) {
            if ($Result.checks.PSObject.Properties[$Name].Value -ne $true) { throw "$Kind failed check $Name." }
        }
        Expand-OwnedPids $Ids
        foreach ($Id in $Ids) { [void]$Script:OwnedPids.Add($Id) }
        $SidecarPid = [int]$Result.sidecarPid
        $Sidecar = Get-CimInstance Win32_Process -Filter "ProcessId = $SidecarPid" -ErrorAction SilentlyContinue
        if ($null -eq $Sidecar -or [int]$Sidecar.ParentProcessId -ne $Process.Id) { throw "$Kind sidecar parentage was invalid." }
        if (-not (Test-ProcessInJob $SidecarPid)) { throw "$Kind sidecar was not contained in a Windows Job Object." }
        if ([string]$Sidecar.CommandLine -match '(?i)--token(?:\s|=)|--handshake-file(?:\s|=)|X-DevPulse-Token|Authorization') {
            throw "$Kind placed a secret transport marker on the sidecar command line."
        }
        $UnexpectedNames = @($Ids | ForEach-Object {
            Get-CimInstance Win32_Process -Filter "ProcessId = $_" -ErrorAction SilentlyContinue
        } | Where-Object {
            -not (Test-ExpectedInstalledDescendant $_ $SidecarPid)
        } | Select-Object -ExpandProperty Name -Unique)
        if ($UnexpectedNames.Count -gt 0) { throw "$Kind created unexpected descendants: $($UnexpectedNames -join ', ')." }
        $NonLoopback = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object {
            $_.OwningProcess -in $Ids -and $_.LocalAddress -notin @("127.0.0.1", "::1")
        })
        if ($NonLoopback.Count -gt 0) { throw "$Kind opened an unexpected non-loopback listener." }
        if (@($Script:ScreenshotRecords | Where-Object { $_.stage -eq "qa-mode-banner" }).Count -eq 0) {
            Save-StageScreenshot "qa-mode-banner" $Process
            Save-StageScreenshot "overview-page" $Process
        }
        [void](Save-EvidenceState "$Kind-readiness" "passed")
        Set-EvidenceStage "$Kind shutdown" "installed-application-shutdown-requested"
        Set-Content -LiteralPath $ObservedPath -Value '{"schemaVersion":1,"observed":true}' -Encoding UTF8
        $ExitDeadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not $Process.HasExited -and [DateTime]::UtcNow -lt $ExitDeadline) {
            Sync-AppDataEvidence
            Expand-OwnedPids $Ids
            Start-Sleep -Milliseconds 100
        }
        if (-not $Process.HasExited) { throw "$Kind did not exit after its bounded successful probe." }
        if ($Process.ExitCode -ne 0) { throw "$Kind exited with code $($Process.ExitCode)." }
        # The desktop can exit before WebView2 and the sidecar finish their normal shutdown.
        # Keep the zero-orphan requirement, but allow the same bounded cleanup window used
        # by interactive-close probes before treating a descendant as residue.
        $CleanupDeadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            Expand-OwnedPids $Ids
            foreach ($Id in $Ids) { [void]$Script:OwnedPids.Add($Id) }
            $Orphans = @($Ids | Where-Object { Test-Alive $_ })
            if ($Orphans.Count -eq 0) { break }
            Sync-AppDataEvidence
            Start-Sleep -Milliseconds 200
        } while ([DateTime]::UtcNow -lt $CleanupDeadline)
        if ($Orphans.Count -gt 0) {
            Stop-RecordedProcesses $Ids
            throw "$Kind left an owned process running after its bounded cleanup window: $($Orphans -join ', ')."
        }
        $Smoke = [ordered]@{
            kind = $Kind
            desktopPid = $Process.Id
            sidecarPid = $SidecarPid
            exitCode = $Process.ExitCode
            exactParentage = $true
            sidecarInWindowsJob = $true
            loopbackOnly = $true
            orphanCount = 0
            checks = $Result.checks
        }
        $Script:SmokeResults += $Smoke
        $Script:ProcessResults += $Smoke
        Write-EvidenceEvent -Event "$Kind-completed" -Result passed -Details $Smoke -ProcessIds @($Ids)
        return $Smoke
    }
    finally {
        if (-not $Process.HasExited) { Stop-RecordedProcesses $Ids }
    }
}

function Assert-NoForbiddenState($State, [string]$Phase) {
    if ($State.machineUninstallEntries.Count -ne 0) { throw "$Phase created a per-machine uninstall entry." }
    if ($State.services.Count -ne 0) { throw "$Phase created a DevPulse service." }
    if ($State.scheduledTasks.Count -ne 0) { throw "$Phase created a DevPulse scheduled task." }
    if ($State.startupEntries.Count -ne 0) { throw "$Phase created a DevPulse startup entry." }
    if ($State.firewallRules.Count -ne 0) { throw "$Phase created a DevPulse firewall rule." }
    if (@($State.protectedDevPulsePaths | Where-Object { $_.exists }).Count -ne 0) { throw "$Phase wrote to Program Files or ProgramData." }
}

function Assert-ProductionDataClean([string]$Phase) {
    Sync-AppDataEvidence
    $Present = @($ProductionDataPaths | Where-Object { Test-Path -LiteralPath $_ })
    if ($Present.Count -gt 0) {
        $Evidence = @($Present | ForEach-Object { Get-TopLevelPathEvidence $_ })
        Write-EvidenceEvent -Event "production-appdata-contamination" -Result failed -Details ([ordered]@{
            phase = $Phase
            paths = $Evidence
        }) -SafePathIdentifiers @($Present | ForEach-Object { ConvertTo-SafePath $_ })
        $SafePresent = @($Present | ForEach-Object { ConvertTo-SafePath $_ })
        throw "$Phase contaminated production-style DevPulse AppData: $($SafePresent -join ', ')."
    }
}

function Assert-PathInsideQaRoot([string]$Path, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "$Label was empty or contained parent traversal."
    }
    $Candidate = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $Root = [System.IO.Path]::GetFullPath($QaRoot).TrimEnd('\')
    if ($Candidate -ne $Root -and -not $Candidate.StartsWith("$Root\", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label resolved outside the canonical QA root."
    }
}

function Remove-ValidatedQaRuntime([string]$Path, [string]$Reason) {
    $Candidate = [System.IO.Path]::GetFullPath($Path)
    $ApprovedRoot = [System.IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($Candidate) -or $Candidate -eq [System.IO.Path]::GetPathRoot($Candidate)) {
        throw "QA cleanup refused an empty path or filesystem root."
    }
    if (-not $Candidate.StartsWith("$ApprovedRoot\", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "QA cleanup refused a path outside the approved runner-temporary root."
    }
    if ([System.IO.Path]::GetFileName($Candidate) -notlike "DevPulse-QA*") {
        throw "QA cleanup refused a directory without the dedicated DevPulse-QA name."
    }
    $Relative = $Candidate.Substring($ApprovedRoot.Length).TrimStart('\')
    if ($Relative.Split('\').Count -ne 1 -or $Relative -match '(^|\\)\.\.(\\|$)') {
        throw "QA cleanup refused a nested or parent-traversal target."
    }
    $Current = $ApprovedRoot
    foreach ($Part in $Relative.Split('\')) {
        $Current = Join-Path $Current $Part
        if (Test-Path -LiteralPath $Current) {
            $Item = Get-Item -LiteralPath $Current -Force
            if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "QA cleanup refused a symbolic-link or junction boundary."
            }
        }
    }
    if (Test-Path -LiteralPath (Join-Path $Candidate ".git")) {
        throw "QA cleanup refused a source-controlled directory."
    }
    if (Test-Path -LiteralPath $Candidate) {
        Write-EvidenceEvent -Event "qa-runtime-cleanup" -Details ([ordered]@{
            path = ConvertTo-SafePath $Candidate
            reason = $Reason
        }) -SafePathIdentifiers @((ConvertTo-SafePath $Candidate))
        Remove-Item -LiteralPath $Candidate -Recurse -Force
    }
}

function Get-UninstallerFromRegistry {
    $Root = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    $Matches = @(Get-ChildItem -LiteralPath $Root | ForEach-Object {
        $Properties = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
        if (Test-DevPulseUninstallEntry -Properties $Properties) { $Properties }
    })
    if ($Matches.Count -ne 1) { throw "Expected one current-user DevPulse uninstall entry." }
    $Command = [string]$Matches[0].UninstallString
    if ($Command -match '^"([^"]+\.exe)"(?:\s.*)?$') { $Path = $Matches[1] }
    elseif ($Command -match '^(.+?\.exe)(?:\s.*)?$') { $Path = $Matches[1] }
    else { throw "The uninstall entry did not contain a parseable executable path." }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "The registered uninstaller does not exist." }
    if ([System.IO.Path]::GetFullPath($Path) -notlike "$ExpectedInstallDirectory\*") { throw "The registered uninstaller is outside the expected current-user installation." }
    return $Path
}

function Invoke-UninstallCycle([string]$Cycle) {
    $Uninstaller = Get-UninstallerFromRegistry
    $Result = Invoke-BoundedExecutable $Uninstaller "/S" "uninstall-$Cycle" 180
    if ($Result.exitCode -ne 0) { throw "$Cycle uninstall failed with exit code $($Result.exitCode)." }
    $Deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ((Test-Path -LiteralPath $ExpectedInstallDirectory) -and [DateTime]::UtcNow -lt $Deadline) { Start-Sleep -Milliseconds 250 }
    $State = Get-ExactState
    Assert-NoForbiddenState $State "$Cycle uninstall"
    if ($State.expectedInstallDirectory.exists) { throw "$Cycle uninstall left the installation directory." }
    if ($State.startMenuDirectory.exists) { throw "$Cycle uninstall left the Start Menu directory." }
    if ($State.desktopShortcut.exists) { throw "$Cycle uninstall left a Desktop shortcut." }
    if ($State.currentUserUninstallEntries.Count -ne 0) { throw "$Cycle uninstall left its registry entry." }
    $OwnedAlive = @($Script:OwnedPids | Where-Object { Test-Alive $_ })
    if ($OwnedAlive.Count -gt 0) { throw "$Cycle uninstall left an owned process running." }
    $Entry = [ordered]@{
        cycle = $Cycle
        uninstallerSource = "current-user uninstall registry entry"
        arguments = "/S"
        exitCode = $Result.exitCode
        installedProgramFilesRemoved = $true
        startMenuRemoved = $true
        desktopShortcutRemoved = $true
        currentUserUninstallEntryRemoved = $true
        forbiddenMachineStateAbsent = $true
        ownedProcessesAbsent = $true
    }
    $Script:UninstallResults += $Entry
    return $Entry
}

# Create placeholders immediately so an always-run artifact step has a complete, bounded report set.
foreach ($Name in @(
    "build-manifest.json", "installer-inspection.json", "pre-install-baseline.json",
    "appdata-write-timeline.json", "installed-state.json", "installed-smoke-results.json",
    "process-ownership-results.json", "immediate-close-results.json", "normal-close-results.json",
    "failure-recovery-results.json", "qa-gate-refusal-results.json", "uninstall-results.json", "residue-audit.json",
    "reinstall-results.json", "final-clean-state.json", "screenshot-index.json"
)) { Write-SafeJson $Name ([ordered]@{ schemaVersion = 1; status = "not-run" }) }
if (Test-Path -LiteralPath $Script:EvidenceTimelinePath) {
    throw "The append-only evidence timeline unexpectedly existed before this run."
}
New-Item -ItemType File -Path $Script:EvidenceTimelinePath | Out-Null
Start-AppDataWatchers
Set-EvidenceStage "initialization" "evidence-capture-started"

try {
    Set-EvidenceStage "artifact verification"
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $InspectionPath -PathType Leaf)) {
        throw "Transferred manifest or installer inspection is missing."
    }
    $Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ($Manifest.devPulseVersion -ne $Version -or $Manifest.commitSha -ne $env:DEVPULSE_TESTED_SHA) { throw "Transferred manifest identity mismatch." }
    $InstallerPath = Join-Path $ArtifactDirectory $Manifest.installerFilename
    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) { throw "Transferred installer is missing." }
    if ((Get-Item -LiteralPath $InstallerPath).Length -ne $Manifest.installerByteSize) { throw "Transferred installer size mismatch." }
    if ((Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash -ne $Manifest.installerSha256) { throw "Transferred installer SHA-256 mismatch." }
    $Signature = Get-AuthenticodeSignature -LiteralPath $InstallerPath
    if ($Signature.Status -ne "NotSigned" -or $Manifest.signingStatus -ne "unsigned") { throw "Signing status changed during transfer." }
    Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $ReportDirectory "build-manifest.json") -Force
    Copy-Item -LiteralPath $InspectionPath -Destination (Join-Path $ReportDirectory "installer-inspection.json") -Force
    Write-EvidenceEvent -Event "transferred-installer-verified" -Result passed -Details ([ordered]@{
        filename = $Manifest.installerFilename
        byteSize = $Manifest.installerByteSize
        sha256 = $Manifest.installerSha256
        signingStatus = $Manifest.signingStatus
    })

    Set-EvidenceStage "pre-install baseline"
    $Baseline = Get-ExactState
    Assert-NoForbiddenState $Baseline "baseline"
    if ($Baseline.expectedInstallDirectory.exists -or $Baseline.currentUserUninstallEntries.Count -ne 0) { throw "Runner was not clean before installation." }
    Assert-ProductionDataClean "baseline"
    Write-SafeJson "pre-install-baseline.json" ([ordered]@{ schemaVersion = 1; status = "passed"; scope = "exact DevPulse locations and names only"; state = $Baseline })
    Save-StageScreenshot "pre-install-desktop"
    [void](Save-EvidenceState "pre-install-baseline" "passed")

    Set-EvidenceStage "first installation"
    Save-StageScreenshot "installer-launch" -SilentProcessExpected
    Write-EvidenceEvent -Event "installer-launch" -Details ([ordered]@{ arguments = "/S"; elevationVerbUsed = $false })
    $Install = Invoke-BoundedExecutable $InstallerPath "/S" "install-first" 180
    if ($Install.exitCode -ne 0) { throw "Installer returned exit code $($Install.exitCode)." }
    $Installed = Get-ExactState
    Assert-NoForbiddenState $Installed "installation"
    if (-not $Installed.expectedInstallDirectory.exists) { throw "Expected current-user installation directory is missing." }
    if ($Installed.currentUserUninstallEntries.Count -ne 1) { throw "Expected one current-user uninstall entry." }
    if (-not $Installed.startMenuDirectory.exists) { throw "Expected Start Menu folder is missing." }
    if (-not $Installed.desktopShortcut.exists) { throw "The standard Tauri silent-install Desktop shortcut is missing." }
    Assert-ProductionDataClean "installation"
    Save-StageScreenshot "installation-completed"
    [void](Save-EvidenceState "first-installation-completed" "passed")
    $InstalledExecutable = Get-InstalledExecutable
    $InstalledSidecar = Get-InstalledSidecar
    $AppInfo = (Get-Item -LiteralPath $InstalledExecutable).VersionInfo
    if ($AppInfo.ProductName -ne "DevPulse" -or $AppInfo.ProductVersion -ne $Version) { throw "Installed application metadata/version mismatch." }
    $SidecarHash = (Get-FileHash -LiteralPath $InstalledSidecar -Algorithm SHA256).Hash
    if ($SidecarHash -ne $Manifest.sidecarSha256) { throw "Installed sidecar hash differs from the build manifest." }
    $InstalledStateReport = [ordered]@{
        schemaVersion = 1; status = "passed"; installArguments = "/S"; installExitCode = $Install.exitCode
        currentUserInstall = $true; elevationVerbUsed = $false; installerExecutionLevel = "asInvoker"
        installationDirectory = ConvertTo-SafePath $ExpectedInstallDirectory
        mainExecutable = [ordered]@{ name = [IO.Path]::GetFileName($InstalledExecutable); version = $AppInfo.ProductVersion; sha256 = (Get-FileHash $InstalledExecutable -Algorithm SHA256).Hash }
        sidecar = [ordered]@{ name = [IO.Path]::GetFileName($InstalledSidecar); sha256 = $SidecarHash }
        currentUserUninstallEntryCount = $Installed.currentUserUninstallEntries.Count
        startMenuShortcut = $Installed.startMenuDirectory.exists
        desktopShortcut = $Installed.desktopShortcut.exists
        desktopShortcutBehavior = "created by the standard Tauri NSIS silent-install path"
        serviceCreated = $false; scheduledTaskCreated = $false; startupEntryCreated = $false; firewallRuleCreated = $false
        perMachineUninstallEntryCreated = $false; protectedLocationCreated = $false; productionAppDataContaminated = $false
        realProjectPathsPresent = $false
    }
    Write-SafeJson "installed-state.json" $InstalledStateReport

    Set-EvidenceStage "installed lifecycle"
    if (Test-Path -LiteralPath $QaRoot) { throw "QA root unexpectedly existed before installed lifecycle testing." }
    New-Item -ItemType Directory -Force -Path $QaRoot | Out-Null
    [void](Save-EvidenceState "before-installed-app-launch" "passed")
    $QaGateRefusals = Invoke-QaGateRefusalTests $InstalledExecutable
    Set-EvidenceStage "installed lifecycle"
    $Python = (Get-Command python.exe -ErrorAction Stop).Source
    $Sentinel = Start-Process -FilePath $Python -ArgumentList '-c "import time; time.sleep(300)"' -WindowStyle Hidden -PassThru
    try {
        1..3 | ForEach-Object {
            Set-EvidenceStage "immediate-close-$_ startup"
            [void](Save-EvidenceState "immediate-close-$_-prelaunch" "passed")
            $Immediate = Start-InstalledQa $InstalledExecutable $false $false
            $WindowDeadline = [DateTime]::UtcNow.AddSeconds(20)
            while ([DateTime]::UtcNow -lt $WindowDeadline -and -not $Immediate.HasExited) {
                Sync-AppDataEvidence
                $Immediate.Refresh()
                if ($Immediate.MainWindowHandle -ne [IntPtr]::Zero) { break }
                Start-Sleep -Milliseconds 100
            }
            if ($Immediate.HasExited -or $Immediate.MainWindowHandle -eq [IntPtr]::Zero) { throw "Immediate-close launch $_ did not create its native window." }
            if ($_ -eq 1) { Save-StageScreenshot "installed-startup" $Immediate }
            Set-EvidenceStage "immediate-close-$_ shutdown"
            $Script:ProcessResults += Stop-InstalledLaunch $Immediate "immediate-close-$_"
        }

        1..3 | ForEach-Object {
            Set-EvidenceStage "normal-smoke-$_ startup"
            [void](Invoke-AutomatedSmoke $InstalledExecutable "normal-smoke-$_")
        }

        # Corrupt only the validated isolated QA root; recovery must regenerate artificial data.
        Set-EvidenceStage "malformed QA configuration recovery"
        Set-Content -LiteralPath (Join-Path $QaRoot "settings.json") -Value "{ malformed" -Encoding UTF8
        New-Item -ItemType Directory -Force -Path (Join-Path $QaRoot "test-lab") | Out-Null
        Set-Content -LiteralPath (Join-Path $QaRoot "test-lab\qa-manifest.json") -Value "[]" -Encoding UTF8
        $Malformed = Invoke-AutomatedSmoke $InstalledExecutable "malformed-qa-recovery"

        $Primary = Start-InstalledQa $InstalledExecutable $false $false
        Start-Sleep -Seconds 3
        $Secondary = Start-InstalledQa $InstalledExecutable $false $false
        if (-not $Secondary.WaitForExit(10000)) { throw "Duplicate secondary launch did not exit promptly." }
        $SecondaryChildren = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($Secondary.Id)")
        if ($SecondaryChildren.Count -ne 0) { throw "Duplicate secondary launch created a child." }
        $Duplicate = [ordered]@{ primaryPid = $Primary.Id; secondaryPid = $Secondary.Id; secondaryExitCode = $Secondary.ExitCode; secondaryChildCount = 0 }
        $Script:ProcessResults += Stop-InstalledLaunch $Primary "duplicate-primary"

        $FailurePath = Join-Path $QaRoot "qa-startup-failure.json"
        Remove-Item -LiteralPath $FailurePath -Force -ErrorAction SilentlyContinue
        $FailureProcess = Start-InstalledQa $InstalledExecutable $false $true
        if (-not (Wait-ForFile $FailurePath 30)) { throw "Sidecar startup-failure marker timed out." }
        $FailureMarker = Get-Content -LiteralPath $FailurePath -Raw | ConvertFrom-Json
        if ($FailureMarker.status -ne "error") { throw "Sidecar startup failure was not reported safely." }
        Save-StageScreenshot "failure-recovery" $FailureProcess
        $FailureClose = Stop-InstalledLaunch $FailureProcess "sidecar-startup-failure"
        if ($Sentinel.HasExited) { throw "The unrelated Python sentinel was terminated by DevPulse." }
        $SentinelSurvived = $true
    }
    finally {
        foreach ($Name in @("Immediate", "Primary", "Secondary", "FailureProcess")) {
            $Candidate = Get-Variable -Name $Name -ValueOnly -ErrorAction SilentlyContinue
            if ($Candidate -is [System.Diagnostics.Process] -and -not $Candidate.HasExited) { Stop-Process -Id $Candidate.Id -Force -ErrorAction SilentlyContinue }
        }
        if ($null -ne $Sentinel -and -not $Sentinel.HasExited) { Stop-Process -Id $Sentinel.Id -Force; $Sentinel.WaitForExit() }
    }
    Set-EvidenceStage "installed lifecycle completed"
    [void](Save-EvidenceState "installed-lifecycle-completed" "passed")
    $QaFiles = @(Get-ChildItem -LiteralPath $QaRoot -Recurse -File)
    foreach ($QaFile in $QaFiles) {
        if ($QaFile.Extension -in @(".json", ".log", ".txt")) {
            $Content = Get-Content -LiteralPath $QaFile.FullName -Raw -ErrorAction SilentlyContinue
            if ($Content -match '(?i)X-DevPulse-Token|gh[pousr]_[A-Za-z0-9_]{20,}') { throw "A QA output contained a credential marker." }
        }
    }
    $DesktopPathReportPath = Join-Path $QaRoot "qa-path-report.json"
    $CorePathReportPath = Join-Path $QaRoot "local-core-path-report.json"
    foreach ($RequiredReport in @($DesktopPathReportPath, $CorePathReportPath)) {
        if (-not (Test-Path -LiteralPath $RequiredReport -PathType Leaf)) {
            throw "Installed QA did not produce required path report $([IO.Path]::GetFileName($RequiredReport))."
        }
    }
    $DesktopPathReport = Get-Content -LiteralPath $DesktopPathReportPath -Raw | ConvertFrom-Json
    $CorePathReport = Get-Content -LiteralPath $CorePathReportPath -Raw | ConvertFrom-Json
    if (-not $DesktopPathReport.allWritablePathsUnderQaRoot -or
        -not $DesktopPathReport.environmentMatchesCanonicalPlan -or
        -not $DesktopPathReport.tauriWebViewDirectoryMatchesCanonicalPlan) {
        throw "The installed desktop resolved a writable path outside its canonical QA plan."
    }
    if (-not $CorePathReport.allWritablePathsUnderQaRoot -or -not $CorePathReport.environmentMatchesCanonicalPlan) {
        throw "The packaged local core resolved a writable path outside its canonical QA plan."
    }
    foreach ($Name in @(
        "qaRoot", "tauriAppConfigurationDirectory", "tauriAppDataDirectory",
        "tauriLocalDataDirectory", "tauriCacheDirectory", "tauriLogDirectory",
        "webView2UserDataDirectory", "pythonLocalCoreConfigurationDirectory",
        "pythonCacheDirectory", "pythonLogDirectory", "qaRepositoryDirectory",
        "diagnosticsExportDirectory", "activityStorage"
    )) {
        Assert-PathInsideQaRoot ([string]$DesktopPathReport.$Name) "desktop path $Name"
    }
    foreach ($Name in @(
        "qaRoot", "pythonLocalCoreConfigurationDirectory", "pythonCacheDirectory",
        "pythonLogDirectory", "qaRepositoryDirectory", "diagnosticsExportDirectory",
        "activityStorage"
    )) {
        Assert-PathInsideQaRoot ([string]$CorePathReport.$Name) "local-core path $Name"
    }
    if ([System.IO.Path]::GetFullPath([string]$DesktopPathReport.webView2UserDataDirectory) -ne [System.IO.Path]::GetFullPath($QaWebView2Data)) {
        throw "WebView2 did not receive the canonical QA user-data directory."
    }
    if (-not $DesktopPathReport.processEnvironment.qaModePresent -or -not $DesktopPathReport.processEnvironment.installQaPresent) {
        throw "Both QA gates did not reach the installed desktop executable."
    }
    if (-not $CorePathReport.environment.qaModePresent -or -not $CorePathReport.environment.installQaPresent) {
        throw "Both QA gates did not reach the packaged local core."
    }
    Write-SafeJson "installed-smoke-results.json" ([ordered]@{
        schemaVersion = 1; status = "passed"; smokeLaunches = $Script:SmokeResults
        immediateClose = $Script:ProcessResults | Where-Object { $_.kind -like "immediate-close-*" }
        malformedQaRecovery = $Malformed; sidecarStartupFailure = [ordered]@{ code = $FailureMarker.code; close = $FailureClose }
        duplicateLaunch = $Duplicate; unrelatedPythonSentinelSurvived = $SentinelSurvived
        qaGateRefusals = $QaGateRefusals; qaRoot = ConvertTo-SafePath $QaRoot
        artificialRepositoriesOnly = $true; canonicalPathIsolation = $true
    })
    Write-SafeJson "immediate-close-results.json" ([ordered]@{
        schemaVersion = 1; status = "passed"
        attempts = @($Script:ProcessResults | Where-Object { $_.kind -like "immediate-close-*" })
        requiredAttemptCount = 3; zeroUnexpectedExitCodes = $true; zeroOrphans = $true
    })
    Write-SafeJson "normal-close-results.json" ([ordered]@{
        schemaVersion = 1; status = "passed"; attempts = $Script:SmokeResults
        requiredAttemptCount = 3; authenticatedReadiness = $true; zeroOrphans = $true
    })
    Write-SafeJson "failure-recovery-results.json" ([ordered]@{
        schemaVersion = 1; status = "passed"; malformedQaConfiguration = $Malformed
        sidecarStartupFailure = [ordered]@{ code = $FailureMarker.code; close = $FailureClose }
        duplicateLaunch = $Duplicate; qaGateRefusals = $QaGateRefusals
        unrelatedPythonSentinelSurvived = $SentinelSurvived
        restartAttemptsBounded = $true; shutdownNonBlocking = $true
    })
    Write-SafeJson "process-ownership-results.json" ([ordered]@{
        schemaVersion = 1; status = "passed"; launches = $Script:ProcessResults
        exactParentage = $true; windowsJobContainment = $true; allOwnedDescendantsExited = $true
        unrelatedPythonSentinelSurvived = $true; globalProcessNameTerminationUsed = $false; restartAttemptsBounded = $true
    })
    foreach ($PathReport in @($DesktopPathReportPath, $CorePathReportPath)) {
        $PathReportName = [IO.Path]::GetFileName($PathReport)
        $SafePathReport = ConvertTo-SafeText (Get-Content -LiteralPath $PathReport -Raw)
        Set-Content -LiteralPath (Join-Path $ReportDirectory $PathReportName) -Value $SafePathReport -Encoding UTF8
    }
    Assert-ProductionDataClean "installed smoke"

    Set-EvidenceStage "first uninstall"
    Save-StageScreenshot "before-uninstall"
    [void](Save-EvidenceState "before-first-uninstall" "passed")
    $FirstUninstall = Invoke-UninstallCycle "first"
    Assert-ProductionDataClean "first uninstall"
    Remove-ValidatedQaRuntime $QaRoot "first uninstall residue audit"
    $ResidueAfterFirst = Get-ExactState
    Save-StageScreenshot "after-uninstall"
    [void](Save-EvidenceState "after-first-uninstall" "passed")
    Write-SafeJson "uninstall-results.json" ([ordered]@{ schemaVersion = 1; status = "passed"; cycles = $Script:UninstallResults })

    Set-EvidenceStage "reinstallation"
    $Reinstall = Invoke-BoundedExecutable $InstallerPath "/S" "install-second" 180
    if ($Reinstall.exitCode -ne 0) { throw "Reinstallation failed with exit code $($Reinstall.exitCode)." }
    $ReinstalledState = Get-ExactState
    Assert-NoForbiddenState $ReinstalledState "reinstallation"
    if (-not $ReinstalledState.expectedInstallDirectory.exists -or $ReinstalledState.currentUserUninstallEntries.Count -ne 1) { throw "Reinstallation state is incomplete." }
    New-Item -ItemType Directory -Force -Path $QaRoot | Out-Null
    $ReinstalledExecutable = Get-InstalledExecutable
    $ReinstallSmoke = Invoke-AutomatedSmoke $ReinstalledExecutable "reinstall-smoke"
    Save-StageScreenshot "reinstalled-application"
    Set-EvidenceStage "final uninstall"
    $FinalUninstall = Invoke-UninstallCycle "final"
    Assert-ProductionDataClean "final uninstall"
    Remove-ValidatedQaRuntime $QaRoot "final uninstall residue audit"
    $FinalState = Get-ExactState
    Assert-NoForbiddenState $FinalState "final residue audit"
    if ($FinalState.expectedInstallDirectory.exists -or $FinalState.currentUserUninstallEntries.Count -ne 0 -or $FinalState.startMenuDirectory.exists -or $FinalState.desktopShortcut.exists) {
        throw "Final residue audit found unexplained executable, shortcut, or registry residue."
    }
    Write-SafeJson "uninstall-results.json" ([ordered]@{ schemaVersion = 1; status = "passed"; cycles = $Script:UninstallResults })
    Write-SafeJson "residue-audit.json" ([ordered]@{
        schemaVersion = 1; status = "passed"; installedProgramResidue = $false; shortcutResidue = $false
        registryResidue = $false; processResidue = $false; serviceResidue = $false; scheduledTaskResidue = $false
        startupResidue = $false; firewallResidue = $false; protectedLocationResidue = $false
        productionAppDataContaminated = $false; qaRuntimeRemovedByHarness = $true
        userDataPolicy = "Production user settings would be preserved by product policy; this disposable run created only isolated QA data and the harness removed it."
    })
    Write-SafeJson "reinstall-results.json" ([ordered]@{
        schemaVersion = 1; status = "passed"; sameArtifactSha256 = $Manifest.installerSha256
        installExitCode = $Reinstall.exitCode; staleStateInterference = $false; smoke = $ReinstallSmoke
        finalUninstall = $FinalUninstall; finalCleanState = $true; upgradeTestPerformed = $false
        upgradeReason = "No trustworthy immutable previous installer artifact was supplied for this sprint."
    })
    Write-SafeJson "final-clean-state.json" ([ordered]@{
        schemaVersion = 1; status = "passed"; timestamp = [DateTime]::UtcNow.ToString("o")
        finalState = $FinalState; productionAppDataContaminated = $false
        devPulseOwnedProcessesRemaining = 0; qaRuntimeRemoved = $true
    })
    Set-EvidenceStage "complete"
    Save-StageScreenshot "final-clean-state"
    [void](Save-EvidenceState "final-clean-state" "passed")
}
catch {
    $Script:FailureMessage = ConvertTo-SafeText $_.Exception.Message
    try {
        Write-EvidenceEvent -Event "installer-qa-failed" -Result failed -Details ([ordered]@{
            error = $Script:FailureMessage
            phase = $Script:CurrentPhase
        })
        [void](Save-EvidenceState "failure-state" "failed")
    }
    catch {
        Write-Warning "Could not capture the final failure-state snapshot: $($_.Exception.Message)"
    }
    throw
}
finally {
    try { Sync-AppDataEvidence } catch { Write-Warning "Could not flush AppData events before process cleanup." }
    foreach ($Id in @($Script:OwnedPids)) {
        if (Test-Alive $Id) {
            Write-EvidenceEvent -Event "bounded-owned-process-failure-cleanup" -Details ([ordered]@{ processId = $Id }) -ProcessIds @($Id)
            Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue
        }
    }
    $Status = if ($null -eq $Script:FailureMessage) { "passed" } else { "failed" }
    try { Stop-AppDataWatchers } catch { Write-Warning "Could not finalize AppData evidence: $($_.Exception.Message)" }
    try { Complete-VisualEvidenceIndex } catch { Write-Warning "Could not finalize visual evidence: $($_.Exception.Message)" }
    try { Write-FinalEvidenceReports $Status } catch { Write-Warning "Could not finalize unified evidence reports: $($_.Exception.Message)" }
    try { Complete-LifecycleRecorder -Recorder $LifecycleRecorder -Result $Status -Summary @{ smokeLaunches = $Script:SmokeResults.Count; currentPhase = $Script:CurrentPhase } } catch { Write-Warning "Could not finalize lifecycle evidence: $($_.Exception.Message)" }
}
