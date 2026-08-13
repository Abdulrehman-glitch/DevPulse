param(
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$CommitSha,
    [Parameter(Mandatory = $true)][string]$SourceReference,
    [Parameter(Mandatory = $true)][string]$RunnerImage,
    [switch]$SkipPayloadInspection
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Version = (Get-Content -LiteralPath (Join-Path $Root "VERSION") -Raw).Trim()
if ($Version -ne "0.3.0-alpha.1") { throw "Installer QA is pinned to 0.3.0-alpha.1." }
$Config = Get-Content -LiteralPath (Join-Path $Root "apps\desktop\src-tauri\tauri.conf.json") -Raw | ConvertFrom-Json
$BundleDirectory = Join-Path $Root "apps\desktop\src-tauri\target\release\bundle\nsis"
$Installers = @(Get-ChildItem -LiteralPath $BundleDirectory -File -Filter "*.exe" | Where-Object {
    $_.Name -match ("^DevPulse_" + [regex]::Escape($Version) + "_x64-setup\.exe$")
})
if ($Installers.Count -ne 1) { throw "Expected exactly one generated NSIS installer for $Version; found $($Installers.Count)." }
$Installer = $Installers[0]
if ($Installer.Name -notmatch [regex]::Escape($Version) -or $Installer.Name -notmatch "_x64-setup\.exe$") {
    throw "Installer filename does not identify DevPulse $Version x64."
}
$MinimumBytes = 15MB
$MaximumBytes = 80MB
if ($Installer.Length -lt $MinimumBytes -or $Installer.Length -gt $MaximumBytes) {
    throw "Installer size $($Installer.Length) is outside the documented 15-80 MiB range."
}
if ($Config.bundle.windows.nsis.installMode -ne "currentUser") { throw "Installer is not current-user mode." }
if ($Config.bundle.windows.webviewInstallMode.type -ne "skip") { throw "Unexpected WebView2 installation mode." }
if ($Config.bundle.publisher -ne "DevPulse contributors" -or $Config.productName -ne "DevPulse") {
    throw "Product and publisher metadata are inconsistent."
}
if ($null -ne $Config.bundle.windows.nsis.PSObject.Properties["installerHooks"]) {
    throw "Custom installer hooks are not permitted."
}
if ($null -ne $Config.PSObject.Properties["plugins"] -and $null -ne $Config.plugins.PSObject.Properties["updater"]) {
    throw "Automatic update configuration is not permitted."
}

$Signature = Get-AuthenticodeSignature -LiteralPath $Installer.FullName
if ($Signature.Status -ne "NotSigned") { throw "The alpha installer must be reported and transferred as unsigned." }
$InstallerBytes = [System.IO.File]::ReadAllBytes($Installer.FullName)
$InstallerAscii = [System.Text.Encoding]::ASCII.GetString($InstallerBytes)
if (-not $InstallerAscii.Contains("requestedExecutionLevel") -or -not $InstallerAscii.Contains("asInvoker")) {
    throw "Installer manifest does not prove asInvoker execution."
}
if ($InstallerAscii.Contains("requireAdministrator")) { throw "Installer requests administrator execution." }

$SevenZip = "C:\Program Files\7-Zip\7z.exe"
if (-not (Test-Path -LiteralPath $SevenZip -PathType Leaf) -and -not $SkipPayloadInspection) {
    throw "The GitHub Windows image 7-Zip installation is required for payload inspection."
}
$ExpectedMainName = "devpulse-desktop.exe"
$ExpectedSidecarName = "devpulse-local-core.exe"
$ExpectedSidecarSourceName = "devpulse-local-core-x86_64-pc-windows-msvc.exe"
$ExpectedUninstallerName = "uninstall.exe"
$ExpectedPayloadExecutableNames = @($ExpectedMainName, $ExpectedSidecarName, $ExpectedUninstallerName)
$PayloadInspectionStatus = "passed"
$UnexpectedExecutables = @()
if (Test-Path -LiteralPath $SevenZip -PathType Leaf) {
    $ArchiveOutput = @(& $SevenZip l -slt $Installer.FullName 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "7-Zip could not inspect the NSIS payload." }
    $PayloadPaths = @($ArchiveOutput | ForEach-Object {
        if ([string]$_ -match "^Path = (.+)$") { $Matches[1] }
    } | Where-Object { $_ })
    $OuterArchiveEntries = @($PayloadPaths | Where-Object {
        [string]::Equals([System.IO.Path]::GetFullPath($_), $Installer.FullName, [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($OuterArchiveEntries.Count -ne 1) {
        throw "7-Zip did not report exactly one outer installer archive entry."
    }
    $PayloadExecutables = @($PayloadPaths | Where-Object {
        $_ -match "\.exe$" -and $_ -notin $OuterArchiveEntries
    })
    foreach ($ExpectedName in $ExpectedPayloadExecutableNames) {
        $ExpectedMatches = @($PayloadExecutables | Where-Object {
            [System.IO.Path]::GetFileName($_) -eq $ExpectedName
        })
        if ($ExpectedMatches.Count -ne 1) {
            throw "Expected exactly one payload executable named $ExpectedName; found $($ExpectedMatches.Count)."
        }
    }
    $UnexpectedExecutables = @($PayloadExecutables | Where-Object {
        [System.IO.Path]::GetFileName($_) -notin $ExpectedPayloadExecutableNames
    })
    if ($UnexpectedExecutables.Count -gt 0) {
        throw "Unexpected executable payload: $($UnexpectedExecutables -join ', ')"
    }
} else {
    $PayloadInspectionStatus = "unavailable-local-7zip-not-installed"
}

$ReleaseExecutable = Join-Path $Root "apps\desktop\src-tauri\target\release\devpulse-desktop.exe"
$Sidecar = Join-Path $Root "apps\desktop\src-tauri\binaries\$ExpectedSidecarSourceName"
if (-not (Test-Path -LiteralPath $ReleaseExecutable -PathType Leaf)) { throw "Release executable is missing." }
if (-not (Test-Path -LiteralPath $Sidecar -PathType Leaf)) { throw "Packaged sidecar is missing." }
$ReleaseInfo = (Get-Item -LiteralPath $ReleaseExecutable).VersionInfo
if ($ReleaseInfo.ProductName -ne "DevPulse" -or $ReleaseInfo.ProductVersion -ne $Version) {
    throw "Visible application product/version metadata is inconsistent with the installer."
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$InstallerHash = (Get-FileHash -LiteralPath $Installer.FullName -Algorithm SHA256).Hash
$SidecarHash = (Get-FileHash -LiteralPath $Sidecar -Algorithm SHA256).Hash
$Inspection = [ordered]@{
    schemaVersion = 1
    status = "passed"
    version = $Version
    installerFilename = $Installer.Name
    installerArchitecture = "x64"
    installerByteSize = $Installer.Length
    expectedSizeRangeBytes = [ordered]@{ minimum = $MinimumBytes; maximum = $MaximumBytes }
    sha256 = $InstallerHash
    signingStatus = "unsigned"
    executionLevel = "asInvoker"
    installMode = "currentUser"
    administratorRequired = $false
    perMachineEnabled = $false
    windowsServiceConfigured = $false
    startupRegistrationConfigured = $false
    automaticUpdatesConfigured = $false
    customInstallerHooksConfigured = $false
    payloadInspectionStatus = $PayloadInspectionStatus
    webView2InstallMode = $Config.bundle.windows.webviewInstallMode.type
    webView2DownloadedByInstaller = $false
    offlineInstallationClaimed = $false
    expectedPayloadExecutables = $ExpectedPayloadExecutableNames
    unexpectedPayloadExecutables = @()
    productName = $Config.productName
    publisher = $Config.bundle.publisher
    visibleApplicationVersion = $ReleaseInfo.ProductVersion
}
$Manifest = [ordered]@{
    schemaVersion = 1
    commitSha = $CommitSha
    sourceReference = $SourceReference
    devPulseVersion = $Version
    installerFilename = $Installer.Name
    installerByteSize = $Installer.Length
    installerSha256 = $InstallerHash
    runnerImage = $RunnerImage
    signingStatus = "unsigned"
    webView2InstallMode = $Config.bundle.windows.webviewInstallMode.type
    sidecarFilename = $ExpectedSidecarName
    sidecarSourceFilename = $ExpectedSidecarSourceName
    sidecarSha256 = $SidecarHash
}
$Inspection | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "installer-inspection.json") -Encoding UTF8
$Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "build-manifest.json") -Encoding UTF8
Copy-Item -LiteralPath $Installer.FullName -Destination (Join-Path $OutputDirectory $Installer.Name)
Write-Host "Installer inspection passed for $($Installer.Name) ($InstallerHash)."
