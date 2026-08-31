$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ScriptPath = Join-Path $PSScriptRoot "inspect-installer.ps1"
$ReleaseCandidateScriptPath = Join-Path $PSScriptRoot "prepare-release-candidate.ps1"
$FixtureDirectory = Join-Path $PSScriptRoot "fixtures\7zip-slt"
$Tokens = $null
$ParseErrors = $null
$ScriptAst = [Management.Automation.Language.Parser]::ParseFile(
    $ScriptPath,
    [ref]$Tokens,
    [ref]$ParseErrors
)
if ($ParseErrors.Count -ne 0) {
    throw "inspect-installer.ps1 did not parse: $($ParseErrors[0].Message)"
}
$FunctionDefinitions = @($ScriptAst.FindAll({
    param($Node)
    $Node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false))
foreach ($Definition in $FunctionDefinitions) {
    Invoke-Expression $Definition.Extent.Text
}
if ($null -eq (Get-Command ConvertFrom-SevenZipSlt -CommandType Function -ErrorAction SilentlyContinue) -or
    $null -eq (Get-Command Get-ValidatedInstallerPayloadExecutables -CommandType Function -ErrorAction SilentlyContinue) -or
    $null -eq (Get-Command Get-RequiredSevenZip -CommandType Function -ErrorAction SilentlyContinue)) {
    throw "The installer inspector does not expose structured 7-Zip listing validation."
}

$ReleaseTokens = $null
$ReleaseParseErrors = $null
$ReleaseScriptAst = [Management.Automation.Language.Parser]::ParseFile(
    $ReleaseCandidateScriptPath,
    [ref]$ReleaseTokens,
    [ref]$ReleaseParseErrors
)
if ($ReleaseParseErrors.Count -ne 0) {
    throw "prepare-release-candidate.ps1 did not parse: $($ReleaseParseErrors[0].Message)"
}
$ReleaseFunctionDefinitions = @($ReleaseScriptAst.FindAll({
    param($Node)
    $Node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false))
foreach ($Definition in $ReleaseFunctionDefinitions) {
    Invoke-Expression $Definition.Extent.Text
}
if ($null -eq (Get-Command Read-PassedInstallerInspection -CommandType Function -ErrorAction SilentlyContinue)) {
    throw "The release candidate gate does not expose installer payload evidence validation."
}

$ExpectedExecutableNames = @(
    "devpulse-desktop.exe",
    "devpulse-local-core.exe",
    "uninstall.exe"
)
$ExpectedInstallerLength = 20971520L
$Passed = 0

try {
    Get-RequiredSevenZip -Path (Join-Path $FixtureDirectory "missing-7z.exe") | Out-Null
}
catch {
    if ($_.Exception.Message -ne "The GitHub Windows image 7-Zip installation is required for payload inspection.") {
        throw "A missing 7-Zip executable failed with an unexpected message: $($_.Exception.Message)"
    }
    $Passed++
}

$UnavailableInspectionPath = [IO.Path]::GetTempFileName()
$PassedInspectionPath = [IO.Path]::GetTempFileName()
@{
    status = "passed"
    payloadInspectionStatus = "unavailable-local-7zip-not-installed"
} | ConvertTo-Json | Set-Content -LiteralPath $UnavailableInspectionPath -Encoding UTF8
try {
    Read-PassedInstallerInspection -Path $UnavailableInspectionPath | Out-Null
}
catch {
    if ($_.Exception.Message -ne "Installer payload inspection evidence did not pass.") {
        throw "Unavailable payload evidence failed with an unexpected message: $($_.Exception.Message)"
    }
    $Passed++
}
@{
    status = "passed"
    payloadInspectionStatus = "passed"
} | ConvertTo-Json | Set-Content -LiteralPath $PassedInspectionPath -Encoding UTF8
$PassedInspection = Read-PassedInstallerInspection -Path $PassedInspectionPath
if ($PassedInspection.payloadInspectionStatus -ne "passed") {
    throw "Passed payload inspection evidence was not returned."
}
$Passed++
Remove-Item -LiteralPath $UnavailableInspectionPath, $PassedInspectionPath -Force

function Read-Fixture {
    param([Parameter(Mandatory = $true)][string]$Name)
    return @(Get-Content -LiteralPath (Join-Path $FixtureDirectory $Name))
}

function Assert-PayloadNames {
    param(
        [Parameter(Mandatory = $true)][string]$Fixture,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $Actual = @(Get-ValidatedInstallerPayloadExecutables `
        -ArchiveOutput (Read-Fixture -Name $Fixture) `
        -InstallerLength $ExpectedInstallerLength `
        -ExpectedExecutableNames $ExpectedExecutableNames)
    $ActualNames = @($Actual | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object)
    $ExpectedNames = @($ExpectedExecutableNames | Sort-Object)
    if (@(Compare-Object -ReferenceObject $ExpectedNames -DifferenceObject $ActualNames).Count -ne 0) {
        throw "$Description returned the wrong executable allowlist: $($ActualNames -join ', ')."
    }
    $script:Passed++
}

function Assert-ThrowsLike {
    param(
        [Parameter(Mandatory = $true)][string]$Fixture,
        [Parameter(Mandatory = $true)][string]$ExpectedMessage,
        [Parameter(Mandatory = $true)][string]$Description
    )

    try {
        @(Get-ValidatedInstallerPayloadExecutables `
            -ArchiveOutput (Read-Fixture -Name $Fixture) `
            -InstallerLength $ExpectedInstallerLength `
            -ExpectedExecutableNames $ExpectedExecutableNames) | Out-Null
    }
    catch {
        if ($_.Exception.Message -notlike $ExpectedMessage) {
            throw "$Description failed with an unexpected message: $($_.Exception.Message)"
        }
        $script:Passed++
        return
    }
    throw "$Description did not fail closed."
}

Assert-PayloadNames `
    -Fixture "nsis-no-outer-path.txt" `
    -Description "A valid NSIS listing without an outer Path record"

$OriginalCulture = [Globalization.CultureInfo]::CurrentCulture
$OriginalUiCulture = [Globalization.CultureInfo]::CurrentUICulture
try {
    $TurkishCulture = [Globalization.CultureInfo]::GetCultureInfo("tr-TR")
    [Globalization.CultureInfo]::CurrentCulture = $TurkishCulture
    [Globalization.CultureInfo]::CurrentUICulture = $TurkishCulture
    Assert-PayloadNames `
        -Fixture "nsis-absolute-outer-path.txt" `
        -Description "A valid NSIS listing with case-varied keys and an absolute outer Path under tr-TR"
}
finally {
    [Globalization.CultureInfo]::CurrentCulture = $OriginalCulture
    [Globalization.CultureInfo]::CurrentUICulture = $OriginalUiCulture
}

Assert-PayloadNames `
    -Fixture "nsis-relative-outer-path.txt" `
    -Description "A valid NSIS listing with a relative outer Path"

Assert-ThrowsLike `
    -Fixture "nsis-missing-expected-executable.txt" `
    -ExpectedMessage "Expected exactly one payload executable named devpulse-local-core.exe; found 0." `
    -Description "A listing missing an expected executable"

Assert-ThrowsLike `
    -Fixture "nsis-duplicate-expected-executable.txt" `
    -ExpectedMessage "Expected exactly one payload executable named devpulse-desktop.exe; found 2." `
    -Description "A listing duplicating an expected executable"

Assert-ThrowsLike `
    -Fixture "nsis-unexpected-executable.txt" `
    -ExpectedMessage "Unexpected executable payload: *unexpected-helper.exe" `
    -Description "A listing containing an unexpected executable"

$MismatchedSize = Read-Fixture -Name "nsis-no-outer-path.txt"
try {
    @(Get-ValidatedInstallerPayloadExecutables `
        -ArchiveOutput $MismatchedSize `
        -InstallerLength ($ExpectedInstallerLength + 1) `
        -ExpectedExecutableNames $ExpectedExecutableNames) | Out-Null
}
catch {
    if ($_.Exception.Message -ne "7-Zip reported an outer NSIS archive physical size that does not match the installer.") {
        throw "A mismatched archive size failed with an unexpected message: $($_.Exception.Message)"
    }
    $Passed++
}
if ($Passed -ne 10) {
    throw "Expected 10 installer archive inspection checks to pass; observed $Passed."
}

Write-Host "Installer archive inspection regression tests passed ($Passed checks)."
