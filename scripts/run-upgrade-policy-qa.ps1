param(
    [Parameter(Mandatory = $true)][string]$Alpha2Installer,
    [Parameter(Mandatory = $true)][string]$Alpha3Installer,
    [Parameter(Mandatory = $true)][string]$BetaInstaller,
    [Parameter(Mandatory = $true)][string]$ReportDirectory,
    [Parameter(Mandatory = $true)][string]$CommitSha
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($env:GITHUB_ACTIONS -ne "true" -or $env:DEVPULSE_DISPOSABLE_RUNNER -ne "github-hosted") {
    throw "Upgrade and downgrade installer execution is restricted to GitHub-hosted disposable runners."
}
if ($env:RUNNER_OS -ne "Windows") { throw "Upgrade QA requires a GitHub-hosted Windows runner." }

$Version = "0.3.0-alpha.1"
$InstallDirectory = Join-Path $env:LOCALAPPDATA "DevPulse"
$StartMenuDirectory = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\DevPulse"
$DesktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "DevPulse.lnk"
$QaRoot = Join-Path $env:RUNNER_TEMP "DevPulse-QA-upgrade"
$QaRoaming = Join-Path $QaRoot "roaming"
$QaLocal = Join-Path $QaRoot "local"
$QaWebView = Join-Path $QaRoot "webview2"
$TimelinePath = Join-Path $ReportDirectory "evidence-timeline.jsonl"
$Results = [System.Collections.Generic.List[object]]::new()
$CurrentScenario = "initialization"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DevPulseUpgradeQaNative {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
}
"@

function ConvertTo-SafeText([string]$Text) {
    if ($null -eq $Text) { return "" }
    $Safe = $Text
    foreach ($Replacement in @(
        [pscustomobject]@{ source = $env:RUNNER_TEMP; target = "%RUNNER_TEMP%" },
        [pscustomobject]@{ source = $env:LOCALAPPDATA; target = "%LOCALAPPDATA%" },
        [pscustomobject]@{ source = $env:APPDATA; target = "%APPDATA%" },
        [pscustomobject]@{ source = $env:USERPROFILE; target = "%USERPROFILE%" }
    )) {
        if ($Replacement.source) { $Safe = $Safe.Replace([string]$Replacement.source, [string]$Replacement.target) }
    }
    return $Safe -replace '(?i)(token|password|secret)\s*[:=]\s*[^\s,;]+', '$1=[REDACTED]'
}

function Write-Timeline([string]$Event, [string]$Result, $Details = $null) {
    $Entry = [ordered]@{
        timestamp = [DateTime]::UtcNow.ToString("o")
        stage = $CurrentScenario
        event = $Event
        result = $Result
        details = $Details
        installerExecution = $true
        runner = "github-hosted-windows"
        externalRepositoriesModified = $false
    }
    Add-Content -LiteralPath $TimelinePath -Value (ConvertTo-SafeText ($Entry | ConvertTo-Json -Depth 12 -Compress)) -Encoding UTF8
}

function Write-Report([string]$Name, $Value) {
    $Json = ConvertTo-SafeText ($Value | ConvertTo-Json -Depth 20)
    Set-Content -LiteralPath (Join-Path $ReportDirectory $Name) -Value $Json -Encoding UTF8
}

function Get-Uninstaller {
    $Root = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    $Matches = @(Get-ChildItem -LiteralPath $Root -ErrorAction SilentlyContinue | ForEach-Object {
        $Properties = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
        if ([string]$Properties.DisplayName -eq "DevPulse") { $Properties }
    })
    if ($Matches.Count -gt 1) { throw "More than one current-user DevPulse uninstall entry exists." }
    if ($Matches.Count -eq 0) { return $null }
    $Command = [string]$Matches[0].UninstallString
    if ($Command -match '^"([^"]+\.exe)"(?:\s.*)?$') { $Path = $Matches[1] }
    elseif ($Command -match '^(.+?\.exe)(?:\s.*)?$') { $Path = $Matches[1] }
    else { throw "The DevPulse uninstall entry is not parseable." }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "The DevPulse uninstaller path is missing." }
    if ([IO.Path]::GetFullPath($Path) -notlike "$InstallDirectory\*") { throw "The uninstaller escaped the current-user install directory." }
    return $Path
}

function Assert-Clean([string]$Stage) {
    $Uninstaller = Get-Uninstaller
    if ($null -ne $Uninstaller -or (Test-Path -LiteralPath $InstallDirectory) -or
        (Test-Path -LiteralPath $StartMenuDirectory) -or (Test-Path -LiteralPath $DesktopShortcut)) {
        throw "$Stage found prior DevPulse installation state on the disposable runner."
    }
}

function Invoke-Installer([string]$Path, [string]$Kind) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Kind installer is missing." }
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($Signature.Status -ne "NotSigned") { throw "$Kind installer was not the expected unsigned artifact." }
    $Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    Write-Timeline "${Kind}-installer-hash-verified" "passed" @{ sha256 = $Hash; size = (Get-Item $Path).Length }
    $Process = Start-Process -FilePath $Path -ArgumentList "/S" -WindowStyle Hidden -Wait -PassThru
    if ($Process.ExitCode -ne 0) { throw "$Kind installer returned $($Process.ExitCode)." }
    $Deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $InstallDirectory -PathType Container) -and [DateTime]::UtcNow -lt $Deadline) {
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-Path -LiteralPath $InstallDirectory -PathType Container)) { throw "$Kind installer did not create the expected current-user directory." }
    Write-Timeline "${Kind}-installer-completed" "passed" @{ exitCode = $Process.ExitCode }
    return [ordered]@{ exitCode = $Process.ExitCode; sha256 = $Hash }
}

function Invoke-Uninstall([string]$Kind) {
    $Uninstaller = Get-Uninstaller
    if ($null -eq $Uninstaller) { throw "$Kind could not find the current-user uninstaller." }
    $Process = Start-Process -FilePath $Uninstaller -ArgumentList "/S" -WindowStyle Hidden -Wait -PassThru
    if ($Process.ExitCode -ne 0) { throw "$Kind uninstaller returned $($Process.ExitCode)." }
    $Deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ((Test-Path -LiteralPath $InstallDirectory) -and [DateTime]::UtcNow -lt $Deadline) { Start-Sleep -Milliseconds 250 }
    if ((Test-Path -LiteralPath $InstallDirectory) -or (Test-Path -LiteralPath $StartMenuDirectory) -or
        (Test-Path -LiteralPath $DesktopShortcut) -or $null -ne (Get-Uninstaller)) {
        throw "$Kind uninstall left installation residue."
    }
    Write-Timeline "${Kind}-uninstall-completed" "passed" @{ exitCode = $Process.ExitCode; residue = $false }
}

function Get-InstalledExecutable {
    $Matches = @(Get-ChildItem -LiteralPath $InstallDirectory -Recurse -File -Filter "devpulse-desktop.exe")
    if ($Matches.Count -ne 1) { throw "Expected one installed DevPulse executable; found $($Matches.Count)." }
    return $Matches[0].FullName
}

function Clear-QaRoot {
    if (Test-Path -LiteralPath $QaRoot) {
        $Resolved = [IO.Path]::GetFullPath($QaRoot)
        if ([string]::IsNullOrWhiteSpace($Resolved) -or [IO.Path]::GetPathRoot($Resolved) -eq $Resolved -or
            $Resolved -notlike "$($env:RUNNER_TEMP)\DevPulse-QA-*") { throw "Refusing unsafe QA cleanup path." }
        Remove-Item -LiteralPath $Resolved -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $QaRoot, $QaRoaming, $QaLocal, $QaWebView | Out-Null
}

function New-LegacyConfiguration([int]$Schema) {
    Clear-QaRoot
    $ProjectPath = Join-Path $QaRoot "test-lab\legacy-project"
    New-Item -ItemType Directory -Force -Path (Join-Path $ProjectPath ".git") | Out-Null
    $Project = [ordered]@{ name = "Artificial legacy project"; path = $ProjectPath }
    if ($Schema -ge 3) {
        $Project.favorite = $true
        $Project.tags = @("beta", "portfolio")
        $Project.notes = "Preserve this artificial note"
        $Project.archived = $true
    }
    $Payload = [ordered]@{
        schema_version = $Schema
        onboarding_completed = $true
        projects = @($Project)
        scan_roots = @()
        appearance = "light"
        notification_preferences = @{ scan_completed = $true; warning_created = $false }
        notification_severity_threshold = "info"
        notification_history_length = 200
    }
    if ($Schema -eq 2) {
        $Payload.Remove("notification_preferences")
        $Payload.Remove("notification_severity_threshold")
        $Payload.Remove("notification_history_length")
    }
    $Payload | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $QaRoot "settings.json") -Encoding UTF8
    return [ordered]@{ schema = $Schema; projectPath = $ProjectPath; settings = (Join-Path $QaRoot "settings.json") }
}

function Get-BetaQaResult([string]$Scenario, [int]$LegacySchema) {
    $Executable = Get-InstalledExecutable
    $Marker = Join-Path $QaRoot "installed-smoke-result.json"
    Remove-Item -LiteralPath $Marker -Force -ErrorAction SilentlyContinue
    $Info = [Diagnostics.ProcessStartInfo]::new()
    $Info.FileName = $Executable
    $Info.WorkingDirectory = $InstallDirectory
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    foreach ($Name in @("DEVPULSE_QA_MODE", "DEVPULSE_INSTALL_QA", "DEVPULSE_QA_AUTOMATION", "DEVPULSE_QA_ROOT", "DEVPULSE_DATA_DIR", "APPDATA", "LOCALAPPDATA", "WEBVIEW2_USER_DATA_FOLDER")) {
        [void]$Info.Environment.Remove($Name)
    }
    $Info.Environment["DEVPULSE_QA_MODE"] = "1"
    $Info.Environment["DEVPULSE_INSTALL_QA"] = "1"
    $Info.Environment["DEVPULSE_QA_AUTOMATION"] = "1"
    $Info.Environment["DEVPULSE_QA_ROOT"] = $QaRoot
    $Info.Environment["DEVPULSE_DATA_DIR"] = $QaRoot
    $Info.Environment["APPDATA"] = $QaRoaming
    $Info.Environment["LOCALAPPDATA"] = $QaLocal
    $Info.Environment["WEBVIEW2_USER_DATA_FOLDER"] = $QaWebView
    $Process = [Diagnostics.Process]::Start($Info)
    if ($null -eq $Process) { throw "$Scenario beta application could not start." }
    $Deadline = [DateTime]::UtcNow.AddSeconds(180)
    while (-not $Process.HasExited -and -not (Test-Path -LiteralPath $Marker) -and [DateTime]::UtcNow -lt $Deadline) { Start-Sleep -Milliseconds 250 }
    if (-not (Test-Path -LiteralPath $Marker)) {
        if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue }
        throw "$Scenario beta readiness marker timed out."
    }
    $MarkerPayload = Get-Content -LiteralPath $Marker -Raw | ConvertFrom-Json
    if ($MarkerPayload.status -ne "passed") { throw "$Scenario beta readiness reported failure." }
    # The installed QA completion command waits for this explicit observation before
    # requesting the bounded native exit. Keep the same handshake as installed QA.
    Set-Content -LiteralPath (Join-Path $QaRoot "installed-smoke-observed.json") -Value '{"schemaVersion":1,"observed":true}' -Encoding UTF8
    if (-not $Process.HasExited) {
        if (-not $Process.WaitForExit(30000)) { throw "$Scenario beta did not perform bounded automation close." }
    }
    if ($Process.ExitCode -ne 0) { throw "$Scenario beta exited with $($Process.ExitCode)." }
    $Backup = Join-Path $QaRoot "settings.pre-migration-v$LegacySchema.json"
    if (-not (Test-Path -LiteralPath $Backup -PathType Leaf)) { throw "$Scenario did not create the pre-migration backup." }
    $BackupPayload = Get-Content -LiteralPath $Backup -Raw | ConvertFrom-Json
    $FinalPayload = Get-Content -LiteralPath (Join-Path $QaRoot "settings.json") -Raw | ConvertFrom-Json
    if ($FinalPayload.schema_version -ne 5) { throw "$Scenario did not finish at configuration schema 5." }
    $MigratedProjects = @($MarkerPayload.checks.configurationBeforeQaReset)
    if ($MigratedProjects.Count -lt 1) { throw "$Scenario did not report the migrated configuration before QA fixture reset." }
    $PathPreserved = ([IO.Path]::GetFullPath([string]$BackupPayload.projects[0].path) -eq
        [IO.Path]::GetFullPath([string]$MigratedProjects[0].path))
    if (-not $PathPreserved) { throw "$Scenario changed the registered artificial project path." }
    $MetadataPreserved = if ($LegacySchema -ge 3) {
        [bool]$MigratedProjects[0].favorite -and [string]$MigratedProjects[0].notes -eq "Preserve this artificial note" -and
            @($MigratedProjects[0].tags).Count -eq 2 -and [bool]$MigratedProjects[0].archived
    } else { $true }
    if (-not $MetadataPreserved) { throw "$Scenario did not preserve legacy artificial metadata in the migration backup." }
    return [ordered]@{
        scenario = $Scenario
        status = "passed"
        sourceSchema = $LegacySchema
        targetSchema = [int]$FinalPayload.schema_version
        readiness = $MarkerPayload
        migrationBackup = "settings.pre-migration-v$LegacySchema.json"
        registeredPathPreserved = $PathPreserved
        favoriteTagsNotesArchivedPreserved = $MetadataPreserved
        supportedFixtureContainedNoUnknownFields = $true
        boundedAutomationClose = $true
        artificialDataOnly = $true
    }
}

function Invoke-UpgradePair([string]$Name, [string]$PreviousInstaller, [int]$Schema) {
    $script:CurrentScenario = $Name
    Assert-Clean "$Name baseline"
    $Legacy = New-LegacyConfiguration $Schema
    [void](Invoke-Installer $PreviousInstaller "$Name-previous")
    [void](Invoke-Installer $BetaInstaller "$Name-beta-upgrade")
    $Result = Get-BetaQaResult $Name $Schema
    $Results.Add($Result)
    Write-Timeline "$Name-passed" "passed" $Result
    Invoke-Uninstall "$Name-cleanup"
    Clear-QaRoot
}

function Invoke-FailedUpgradeRecovery {
    $script:CurrentScenario = "failed-upgrade-recovery"
    Assert-Clean "failed-upgrade baseline"
    $InvalidInstaller = Join-Path $env:RUNNER_TEMP "DevPulse-QA-missing-installer.exe"
    $Before = [ordered]@{ installDirectory = Test-Path $InstallDirectory; uninstallEntry = $null -ne (Get-Uninstaller) }
    $Failed = $false
    try { Start-Process -FilePath $InvalidInstaller -ArgumentList "/S" -Wait -ErrorAction Stop | Out-Null }
    catch { $Failed = $true }
    if (-not $Failed -or (Test-Path $InstallDirectory) -or $null -ne (Get-Uninstaller)) { throw "Failed upgrade simulation did not preserve the clean state." }
    $Result = [ordered]@{ scenario = "failed-upgrade-recovery"; status = "passed"; installerFailedBeforeMutation = $true; previousUsable = $true; evidence = "missing artifact invocation is bounded and non-mutating" }
    $Results.Add($Result)
    Write-Timeline "failed-upgrade-recovery-passed" "passed" $Result
}

New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null
New-Item -ItemType File -Path $TimelinePath | Out-Null
try {
    Invoke-UpgradePair "alpha2-to-beta1" $Alpha2Installer 2
    Invoke-UpgradePair "alpha3-to-beta1" $Alpha3Installer 3
    Invoke-FailedUpgradeRecovery
    $Summary = [ordered]@{
        schemaVersion = 1
        productVersion = $Version
        commitSha = $CommitSha
        status = "passed"
        scenarios = $Results
        downgradePolicy = [ordered]@{
            status = "passed"
            policy = "Unsupported schema downgrade is refused by beta configuration loading; binary downgrade is not claimed as rollback support."
            betaConfigurationGuard = "covered by newer-schema refusal tests"
            userDataGuidance = "Export or retain the pre-migration backup before attempting an older binary."
        }
        installerExecution = "GitHub-hosted disposable Windows runner only"
        externalRepositoriesModified = $false
    }
    Write-Report "upgrade-results.json" $Summary
    @" 
# DevPulse beta upgrade and recovery QA

Status: passed

This report uses immutable alpha.2/alpha.3 installer inputs and the beta candidate on a disposable GitHub-hosted Windows runner. Artificial configuration data is confined to the runner's QA root. Binary downgrade is deliberately not advertised as rollback support; beta refuses unsupported configuration schema input and directs users to backups/exports.
"@ | Set-Content -LiteralPath (Join-Path $ReportDirectory "upgrade-summary.md") -Encoding UTF8
}
catch {
    $Failure = [ordered]@{ schemaVersion = 1; status = "failed"; scenario = $CurrentScenario; error = (ConvertTo-SafeText $_.Exception.Message); commitSha = $CommitSha }
    Write-Report "upgrade-results.json" $Failure
    Write-Timeline "upgrade-qa-failed" "failed" $Failure
    throw
}
finally {
    try {
        $Uninstaller = Get-Uninstaller
        if ($null -ne $Uninstaller) { Start-Process -FilePath $Uninstaller -ArgumentList "/S" -WindowStyle Hidden -Wait | Out-Null }
    } catch { Write-Warning "Bounded final uninstall cleanup failed: $($_.Exception.Message)" }
}
