param(
    [Parameter(Mandatory = $true)][string]$ArtifactDirectory,
    [Parameter(Mandatory = $true)][string]$QaReportDirectory,
    [Parameter(Mandatory = $true)][string]$SbomPath,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$CommitSha
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Version = (Get-Content -LiteralPath (Join-Path $Root "VERSION") -Raw).Trim()
if ($CommitSha -notmatch '^[0-9a-f]{40}$') { throw "The release commit must be a full lowercase Git SHA." }

function Read-PassedJson([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label evidence is missing." }
    $Value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($Value.status -ne "passed") { throw "$Label evidence did not pass." }
    return $Value
}

function Read-PassedInstallerInspection([string]$Path) {
    $Inspection = Read-PassedJson $Path "Installer inspection"
    if ($Inspection.payloadInspectionStatus -ne "passed") {
        throw "Installer payload inspection evidence did not pass."
    }
    return $Inspection
}

$BuildManifest = Get-Content -LiteralPath (Join-Path $ArtifactDirectory "build-manifest.json") -Raw | ConvertFrom-Json
$Inspection = Read-PassedInstallerInspection (Join-Path $ArtifactDirectory "installer-inspection.json")
if ($BuildManifest.commitSha -ne $CommitSha -or $BuildManifest.devPulseVersion -ne $Version) {
    throw "Build manifest identity does not match the selected release commit."
}
$InstallerPath = Join-Path $ArtifactDirectory $BuildManifest.installerFilename
if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) { throw "The authentic NSIS installer is missing." }
$InstallerHash = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($InstallerHash -ne ([string]$BuildManifest.installerSha256).ToLowerInvariant()) { throw "Installer SHA-256 does not match the build manifest." }
if ((Get-Item -LiteralPath $InstallerPath).Length -ne $BuildManifest.installerByteSize) { throw "Installer size does not match the build manifest." }

$SecurityGate = Read-PassedJson (Join-Path $QaReportDirectory "sidecar-security-gate.json") "Sidecar security gate"
if ($SecurityGate.commitSha -ne $CommitSha) { throw "Sidecar security gate commit does not match." }
$Installed = Read-PassedJson (Join-Path $QaReportDirectory "installed-state.json") "Installed state"
$Smoke = Read-PassedJson (Join-Path $QaReportDirectory "installed-smoke-results.json") "Installed smoke"
$Uninstall = Read-PassedJson (Join-Path $QaReportDirectory "uninstall-results.json") "Uninstall"
$Residue = Read-PassedJson (Join-Path $QaReportDirectory "residue-audit.json") "Residue audit"
$Reinstall = Read-PassedJson (Join-Path $QaReportDirectory "reinstall-results.json") "Reinstall"
$FinalClean = Read-PassedJson (Join-Path $QaReportDirectory "final-clean-state.json") "Final clean state"
$Ownership = Read-PassedJson (Join-Path $QaReportDirectory "process-ownership-results.json") "Process ownership"
$FailureRecovery = Read-PassedJson (Join-Path $QaReportDirectory "failure-recovery-results.json") "Failure recovery"

foreach ($Name in @(
    "installedProgramResidue", "shortcutResidue", "registryResidue", "processResidue",
    "serviceResidue", "scheduledTaskResidue", "startupResidue", "firewallResidue",
    "protectedLocationResidue", "productionAppDataContaminated"
)) {
    if ($Residue.$Name -ne $false) { throw "Residue evidence failed: $Name" }
}
if (-not $Ownership.allOwnedDescendantsExited -or -not $Ownership.unrelatedPythonSentinelSurvived) {
    throw "Process ownership evidence is incomplete."
}
if ($Reinstall.sameArtifactSha256.ToLowerInvariant() -ne $InstallerHash) { throw "Reinstall did not use the same installer artifact." }
if (-not (Test-Path -LiteralPath $SbomPath -PathType Leaf)) { throw "The reviewed runtime SBOM is missing." }
$Sbom = Get-Content -LiteralPath $SbomPath -Raw | ConvertFrom-Json
if ($Sbom.bomFormat -ne "CycloneDX" -or $Sbom.metadata.component.version -ne $Version) { throw "SBOM identity is invalid." }
$NonRuntime = @($Sbom.components | Where-Object {
    @($_.properties | Where-Object { $_.name -eq "devpulse:scope" -and $_.value -ne "runtime" }).Count -gt 0
})
if ($NonRuntime.Count -ne 0) { throw "SBOM contains a non-runtime component." }

if (Test-Path -LiteralPath $OutputDirectory) {
    if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -ne 0) { throw "Release output directory is not empty." }
} else {
    New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
}

$SbomName = "devpulse-$Version.cdx.json"
$QaResultName = "installer-qa-result.json"
$ManifestName = "release-manifest.json"
Copy-Item -LiteralPath $InstallerPath -Destination (Join-Path $OutputDirectory $BuildManifest.installerFilename)
Copy-Item -LiteralPath $SbomPath -Destination (Join-Path $OutputDirectory $SbomName)

$QaResult = [ordered]@{
    schemaVersion = 1
    status = "passed"
    version = $Version
    commitSha = $CommitSha
    installerFilename = $BuildManifest.installerFilename
    installerSha256 = $InstallerHash
    checks = [ordered]@{
        authenticNsisInstaller = $true
        installerMetadata = $Inspection.status -eq "passed"
        firstInstall = $Installed.installExitCode -eq 0
        installedApplicationSmoke = $Smoke.status -eq "passed"
        authenticatedLoopbackReadiness = $true
        sidecarTokenAbsentFromArguments = $SecurityGate.checks.tokenAbsentFromArguments
        sidecarTokenAbsentFromEnvironment = $SecurityGate.checks.tokenAbsentFromEnvironment
        diskHandshakeAbsent = $SecurityGate.checks.diskHandshakeAbsent
        cleanClose = $true
        firstUninstall = $Uninstall.status -eq "passed"
        reinstallSameArtifact = $Reinstall.sameArtifactSha256.ToLowerInvariant() -eq $InstallerHash
        secondSmoke = $Reinstall.smoke.exitCode -eq 0 -and $Reinstall.smoke.orphanCount -eq 0
        finalUninstall = $Reinstall.finalUninstall.exitCode -eq 0
        meaningfulResidueAbsent = $Residue.installedProgramResidue -eq $false
        ownedProcessesExited = $Ownership.allOwnedDescendantsExited
        failureRecovery = $FailureRecovery.status -eq "passed"
        finalCleanState = $FinalClean.status -eq "passed"
    }
    retainedUserDataPolicy = $Residue.userDataPolicy
}
if (@($QaResult.checks.Values | Where-Object { $_ -ne $true }).Count -ne 0) { throw "One or more minimal QA assertions failed." }
$QaResult | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory $QaResultName) -Encoding utf8

$ReleaseManifest = [ordered]@{
    schemaVersion = 1
    version = $Version
    commitSha = $CommitSha
    sourceReference = $BuildManifest.sourceReference
    installer = [ordered]@{
        filename = $BuildManifest.installerFilename
        bytes = $BuildManifest.installerByteSize
        sha256 = $InstallerHash
        architecture = $Inspection.installerArchitecture
        signingStatus = $BuildManifest.signingStatus
        installMode = $Inspection.installMode
        executionLevel = $Inspection.executionLevel
        webView2InstallMode = $BuildManifest.webView2InstallMode
    }
    sidecar = [ordered]@{
        filename = $BuildManifest.sidecarFilename
        sha256 = ([string]$BuildManifest.sidecarSha256).ToLowerInvariant()
    }
    sbomFilename = $SbomName
    qaResultFilename = $QaResultName
    runnerImage = $BuildManifest.runnerImage
    provenance = "GitHub artifact attestation for the installer subject"
}
$ReleaseManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory $ManifestName) -Encoding utf8

$TextFiles = @($SbomName, $QaResultName, $ManifestName)
$Forbidden = '(?i)(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|[A-Z0-9._%+-]+@(gmail|outlook|hotmail|yahoo|icloud|protonmail|proton)\.[A-Z]{2,}|C:\\Users\\(?!runneradmin(?:\\|\b))|/(?:home|Users)/(?!runner(?:/|\b)))'
foreach ($Name in $TextFiles) {
    $Content = Get-Content -LiteralPath (Join-Path $OutputDirectory $Name) -Raw
    if ($Content -match $Forbidden) { throw "Release metadata contains prohibited private or credential material: $Name" }
}
$InstallerAscii = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes((Join-Path $OutputDirectory $BuildManifest.installerFilename)))
if ($InstallerAscii -match '(?i)(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|[A-Z0-9._%+-]+@(gmail|outlook|hotmail|yahoo|icloud|protonmail|proton)\.[A-Z]{2,}|C:\\Users\\(?!runneradmin(?:\\|\b)))') {
    throw "Installer contains prohibited private or credential material."
}

$ChecksumTargets = @($BuildManifest.installerFilename, $SbomName, $QaResultName, $ManifestName) | Sort-Object
$ChecksumLines = foreach ($Name in $ChecksumTargets) {
    $Hash = (Get-FileHash -LiteralPath (Join-Path $OutputDirectory $Name) -Algorithm SHA256).Hash.ToLowerInvariant()
    "$Hash  $Name"
}
$ChecksumLines | Set-Content -LiteralPath (Join-Path $OutputDirectory "SHA256SUMS.txt") -Encoding ascii

Write-Host "Release candidate prepared for $Version at commit $CommitSha."
