param(
    [Parameter(Mandatory = $true)][string]$Path,
    [ValidateSet("any", "unsigned", "valid", "invalid-tampered", "untrusted", "expired", "unsupported", "unknown-error")]
    [string]$ExpectedState = "any",
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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

function Get-CertificateTimeState($Certificate, [DateTime]$AtUtc) {
    if ($null -eq $Certificate) { return "not-available" }
    if ($Certificate.NotBefore.ToUniversalTime() -gt $AtUtc) { return "not-yet-valid" }
    if ($Certificate.NotAfter.ToUniversalTime() -lt $AtUtc) { return "expired" }
    return "current"
}

$SignerTimeState = Get-CertificateTimeState $Signer $Now
$VerificationState = switch ([string]$Signature.Status) {
    "NotSigned" { "unsigned"; break }
    "Valid" { "valid"; break }
    "HashMismatch" { "invalid-tampered"; break }
    "NotTrusted" { "untrusted"; break }
    "NotSupportedFileFormat" { "unsupported"; break }
    "NotSupported" { "unsupported"; break }
    "UnknownError" {
        if ($SignerTimeState -eq "expired" -and $null -eq $TimeStamper) { "expired" }
        elseif (@($ChainStatus | Where-Object { $_ -in @("UntrustedRoot", "PartialChain") }).Count -gt 0) { "untrusted" }
        else { "unknown-error" }
        break
    }
    default { "unknown-error" }
}

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
