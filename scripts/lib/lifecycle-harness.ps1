$ErrorActionPreference = "Stop"

function Convert-LifecycleCreationUtc {
    param($Value)

    if ($null -eq $Value) { return $null }
    try {
        if ($Value -is [DateTime]) {
            return $Value.ToUniversalTime().ToString("o")
        }
        return ([System.Management.ManagementDateTimeConverter]::ToDateTime([string]$Value)).ToUniversalTime().ToString("o")
    } catch {
        return $null
    }
}

function Get-LifecycleProcessSnapshot {
    param([Parameter(Mandatory = $true)][int]$Id)

    if ($Id -le 0) { return $null }
    $Process = Get-CimInstance Win32_Process -Filter "ProcessId = $Id" -ErrorAction SilentlyContinue
    if ($null -eq $Process) { return $null }
    return [ordered]@{
        processId = [int]$Process.ProcessId
        parentProcessId = [int]$Process.ParentProcessId
        name = [string]$Process.Name
        executablePath = [string]$Process.ExecutablePath
        creationUtc = Convert-LifecycleCreationUtc $Process.CreationDate
    }
}

function Get-LifecycleProcessTable {
    return @(Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object {
        [ordered]@{
            processId = [int]$_.ProcessId
            parentProcessId = [int]$_.ParentProcessId
            name = [string]$_.Name
            executablePath = [string]$_.ExecutablePath
            creationUtc = Convert-LifecycleCreationUtc $_.CreationDate
        }
    })
}

function Register-LifecycleProcessIdentity {
    param(
        [Parameter(Mandatory = $true)][hashtable]$IdentityMap,
        [Parameter(Mandatory = $true)][int]$Id
    )

    $Key = [string]$Id
    if ($IdentityMap.ContainsKey($Key)) { return $IdentityMap[$Key] }
    $Snapshot = Get-LifecycleProcessSnapshot $Id
    if ($null -eq $Snapshot) { return $null }
    $IdentityMap[$Key] = [ordered]@{
        processId = $Snapshot.processId
        name = $Snapshot.name
        executablePath = $Snapshot.executablePath
        creationUtc = $Snapshot.creationUtc
    }
    return $IdentityMap[$Key]
}

function Test-LifecycleProcessIdentity {
    param(
        [Parameter(Mandatory = $true)][hashtable]$IdentityMap,
        [Parameter(Mandatory = $true)][int]$Id
    )

    $Expected = $IdentityMap[[string]$Id]
    if ($null -eq $Expected) { return $false }
    $Current = Get-LifecycleProcessSnapshot $Id
    if ($null -eq $Current) { return $false }
    if ($Expected.name -and $Current.name -ne $Expected.name) { return $false }
    if ($Expected.creationUtc -and $Current.creationUtc -and $Current.creationUtc -ne $Expected.creationUtc) { return $false }
    if ($Expected.executablePath -and $Current.executablePath -and
        $Current.executablePath -ne $Expected.executablePath) { return $false }
    return $true
}

function Test-LifecycleSnapshotIdentity {
    param(
        [Parameter(Mandatory = $true)][hashtable]$IdentityMap,
        [Parameter(Mandatory = $true)][AllowNull()]$Snapshot
    )

    if ($null -eq $Snapshot) { return $false }
    $Expected = $IdentityMap[[string]$Snapshot.processId]
    if ($null -eq $Expected) { return $false }
    if ($Expected.name -and $Snapshot.name -ne $Expected.name) { return $false }
    if ($Expected.creationUtc -and $Snapshot.creationUtc -and $Snapshot.creationUtc -ne $Expected.creationUtc) { return $false }
    if ($Expected.executablePath -and $Snapshot.executablePath -and
        $Snapshot.executablePath -ne $Expected.executablePath) { return $false }
    return $true
}

function Test-LifecycleChildSnapshotRelationship {
    param(
        [Parameter(Mandatory = $true)][hashtable]$IdentityMap,
        [AllowNull()]$ParentSnapshot,
        [AllowNull()]$ChildSnapshot
    )

    if (-not (Test-LifecycleSnapshotIdentity $IdentityMap $ParentSnapshot) -or $null -eq $ChildSnapshot) { return $false }
    if ($ParentSnapshot.creationUtc -and $ChildSnapshot.creationUtc) {
        try {
            if ([DateTime]::Parse($ChildSnapshot.creationUtc).ToUniversalTime() -le [DateTime]::Parse($ParentSnapshot.creationUtc).ToUniversalTime()) {
                return $false
            }
        } catch {
            return $false
        }
    }
    return $true
}

function Test-LifecycleChildProcessRelationship {
    param(
        [Parameter(Mandatory = $true)][hashtable]$IdentityMap,
        [Parameter(Mandatory = $true)][int]$ParentId,
        [Parameter(Mandatory = $true)][int]$ChildId
    )

    if (-not (Test-LifecycleProcessIdentity $IdentityMap $ParentId)) { return $false }
    $Parent = Get-LifecycleProcessSnapshot $ParentId
    $Child = Get-LifecycleProcessSnapshot $ChildId
    if ($null -eq $Parent -or $null -eq $Child) { return $false }
    if ($Parent.creationUtc -and $Child.creationUtc) {
        try {
            if ([DateTime]::Parse($Child.creationUtc).ToUniversalTime() -le [DateTime]::Parse($Parent.creationUtc).ToUniversalTime()) {
                return $false
            }
        } catch {
            return $false
        }
    }
    return $true
}

function New-LifecycleRecorder {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Scenario,
        [string]$Version = "unknown",
        [string]$CommitSha = "unknown"
    )
    $Canonical = [System.IO.Path]::GetFullPath($Directory)
    if ([string]::IsNullOrWhiteSpace($Canonical) -or [System.IO.Path]::GetPathRoot($Canonical) -eq $Canonical) {
        throw "Lifecycle evidence directory must be a non-root path."
    }
    New-Item -ItemType Directory -Force -Path $Canonical | Out-Null
    $Recorder = [pscustomobject]@{
        directory = $Canonical
        timeline = Join-Path $Canonical "lifecycle-timeline.jsonl"
        scenario = $Scenario
        version = $Version
        commitSha = $CommitSha
        startedUtc = [DateTime]::UtcNow.ToString("o")
    }
    Write-LifecycleTransition -Recorder $Recorder -State "harness-started"
    return $Recorder
}

function Write-LifecycleTransition {
    param(
        [Parameter(Mandatory = $true)]$Recorder,
        [Parameter(Mandatory = $true)][string]$State,
        [int]$DesktopPid = 0,
        [int[]]$OwnedPids = @(),
        [hashtable]$Details = @{}
    )
    $Event = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString("o")
        scenario = $Recorder.scenario
        version = $Recorder.version
        commitSha = $Recorder.commitSha
        state = $State
        desktopPid = if ($DesktopPid -gt 0) { $DesktopPid } else { $null }
        ownedPids = @($OwnedPids | Sort-Object -Unique)
        details = $Details
    }
    ($Event | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $Recorder.timeline -Encoding UTF8
}

function Complete-LifecycleRecorder {
    param(
        [Parameter(Mandatory = $true)]$Recorder,
        [ValidateSet("passed", "failed")][string]$Result,
        [hashtable]$Summary = @{}
    )
    Write-LifecycleTransition -Recorder $Recorder -State "harness-completed" -Details @{ result = $Result }
    $Manifest = [ordered]@{
        schemaVersion = 1
        scenario = $Recorder.scenario
        version = $Recorder.version
        commitSha = $Recorder.commitSha
        result = $Result
        startedUtc = $Recorder.startedUtc
        completedUtc = [DateTime]::UtcNow.ToString("o")
        summary = $Summary
        timeline = (Split-Path -Leaf $Recorder.timeline)
    }
    $Manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Recorder.directory "lifecycle-manifest.json") -Encoding UTF8
}
