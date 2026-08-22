param(
    [Parameter(Mandatory = $true, ParameterSetName = "Verify")][string]$Path,
    [ValidateSet("any", "unsigned", "valid", "invalid-tampered", "untrusted", "expired", "unsupported", "unknown-error")]
    [string]$ExpectedState = "any",
    [Parameter(ParameterSetName = "Verify")][string]$OutputPath,
    [Parameter(Mandatory = $true, ParameterSetName = "ClassifierSelfTest")][switch]$ClassifierSelfTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-CertificateTimeState($Certificate, [DateTime]$AtUtc) {
    if ($null -eq $Certificate) { return "not-available" }
    if ($Certificate.NotBefore.ToUniversalTime() -gt $AtUtc) { return "not-yet-valid" }
    if ($Certificate.NotAfter.ToUniversalTime() -lt $AtUtc) { return "expired" }
    return "current"
}

function Get-VerificationState(
    [string]$WindowsStatus,
    [string]$SignerTimeState,
    [string[]]$ChainStatus,
    [bool]$TimestampPresent
) {
    switch ($WindowsStatus) {
    "NotSigned" { "unsigned"; break }
    "Valid" { "valid"; break }
    "HashMismatch" { "invalid-tampered"; break }
    "NotTrusted" { "untrusted"; break }
    "NotSupportedFileFormat" { "unsupported"; break }
    "NotSupported" { "unsupported"; break }
    "UnknownError" {
        if ($SignerTimeState -eq "expired" -and -not $TimestampPresent) { "expired" }
        elseif (@($ChainStatus | Where-Object { $_ -in @("UntrustedRoot", "PartialChain") }).Count -gt 0) { "untrusted" }
        else { "unknown-error" }
        break
    }
    default { "unknown-error" }
    }
}

if ($ClassifierSelfTest) {
    $Cases = [ordered]@{
        unsigned = Get-VerificationState "NotSigned" "not-available" @() $false
        valid = Get-VerificationState "Valid" "current" @() $true
        invalidTampered = Get-VerificationState "HashMismatch" "current" @() $false
        untrusted = Get-VerificationState "NotTrusted" "current" @("UntrustedRoot") $false
        expired = Get-VerificationState "UnknownError" "expired" @() $false
        unsupported = Get-VerificationState "NotSupportedFileFormat" "not-available" @() $false
        unknownError = Get-VerificationState "UnknownError" "current" @() $false
    }
    $Expected = [ordered]@{
        unsigned = "unsigned"
        valid = "valid"
        invalidTampered = "invalid-tampered"
        untrusted = "untrusted"
        expired = "expired"
        unsupported = "unsupported"
        unknownError = "unknown-error"
    }
    foreach ($Name in $Expected.Keys) {
        if ($Cases[$Name] -ne $Expected[$Name]) { throw "Authenticode classifier self-test failed: $Name." }
    }
    [ordered]@{
        schemaVersion = 1
        status = "passed"
        cases = $Cases
    } | ConvertTo-Json -Depth 5
    return
}

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Authenticode verification target is not a file."
}

$ResolvedPath = (Resolve-Path -LiteralPath $Path).Path
$Signature = Get-AuthenticodeSignature -LiteralPath $ResolvedPath
$Signer = $Signature.SignerCertificate
$TimeStamper = $Signature.TimeStamperCertificate
$Now = [DateTime]::UtcNow
$ChainStatus = @()
if ($null -ne $Signer) {
    $Chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
    try {
        $Chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        [void]$Chain.Build($Signer)
        $ChainStatus = @($Chain.ChainStatus | ForEach-Object { $_.Status.ToString() } | Sort-Object -Unique)
    }
    finally {
        $Chain.Dispose()
    }
}

$SignerTimeState = Get-CertificateTimeState $Signer $Now
$VerificationState = Get-VerificationState `
    -WindowsStatus ([string]$Signature.Status) `
    -SignerTimeState $SignerTimeState `
    -ChainStatus $ChainStatus `
    -TimestampPresent ($null -ne $TimeStamper)

$Result = [ordered]@{
    schemaVersion = 1
    filename = [IO.Path]::GetFileName($ResolvedPath)
    verificationState = $VerificationState
    windowsStatus = [string]$Signature.Status
    signerCertificateTimeState = $SignerTimeState
    timestampPresent = $null -ne $TimeStamper
    timestampCertificateTimeState = Get-CertificateTimeState $TimeStamper $Now
    chainStatus = $ChainStatus
    checkedAtUtc = $Now.ToString("o")
}
$Json = $Result | ConvertTo-Json -Depth 5

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputParent = Split-Path -Parent $OutputPath
    if ($OutputParent) { New-Item -ItemType Directory -Force -Path $OutputParent | Out-Null }
    Set-Content -LiteralPath $OutputPath -Value $Json -Encoding utf8
}

$Json
if ($ExpectedState -ne "any" -and $VerificationState -ne $ExpectedState) {
    throw "Authenticode state was '$VerificationState'; expected '$ExpectedState'."
}
