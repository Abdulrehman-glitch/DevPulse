param(
    [Parameter(Mandatory = $true)][string]$UnsignedExecutable,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (
    $env:GITHUB_ACTIONS -ne "true" -or
    $env:RUNNER_ENVIRONMENT -ne "github-hosted" -or
    $env:RUNNER_OS -ne "Windows"
) {
    throw "The ephemeral certificate test is restricted to a disposable GitHub-hosted Windows runner."
}
if (-not (Test-Path -LiteralPath $UnsignedExecutable -PathType Leaf)) {
    throw "The unsigned executable fixture is missing."
}

$Verifier = Join-Path $PSScriptRoot "verify-authenticode.ps1"
$TestRoot = Join-Path $env:RUNNER_TEMP "DevPulse-Authenticode-ephemeral-TEST-$PID"
$RunnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$CanonicalTestRoot = [IO.Path]::GetFullPath($TestRoot)
if ($CanonicalTestRoot -notlike "$RunnerTemp\*") { throw "Ephemeral signing test escaped RUNNER_TEMP." }

$Certificate = $null
$UntrustedCertificate = $null
$ImportedRoot = $null
$ImportedPublisher = $null
try {
    New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null
    $UnsignedCopy = Join-Path $TestRoot "unsigned-fixture.exe"
    $SignedCopy = Join-Path $TestRoot "signed-ephemeral-TEST-fixture.exe"
    $UntrustedCopy = Join-Path $TestRoot "untrusted-ephemeral-TEST-fixture.exe"
    $TamperedCopy = Join-Path $TestRoot "tampered-fixture.exe"
    $PublicCertificate = Join-Path $TestRoot "ephemeral-public-TEST-only.cer"
    Copy-Item -LiteralPath $UnsignedExecutable -Destination $UnsignedCopy

    $Unsigned = (& $Verifier -Path $UnsignedCopy -ExpectedState unsigned) | ConvertFrom-Json
    $Certificate = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject "CN=DevPulse Ephemeral TEST Certificate Only" `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -KeyExportPolicy NonExportable `
        -NotAfter (Get-Date).AddDays(1)
    Export-Certificate -Cert $Certificate -FilePath $PublicCertificate -Force | Out-Null
    $ImportedRoot = Import-Certificate -FilePath $PublicCertificate -CertStoreLocation "Cert:\CurrentUser\Root"
    $ImportedPublisher = Import-Certificate -FilePath $PublicCertificate -CertStoreLocation "Cert:\CurrentUser\TrustedPublisher"

    Copy-Item -LiteralPath $UnsignedExecutable -Destination $SignedCopy
    $SigningResult = Set-AuthenticodeSignature -LiteralPath $SignedCopy -Certificate $Certificate -HashAlgorithm SHA256
    if ($SigningResult.Status -ne "Valid") {
        throw "The ephemeral TEST signature could not be validated on the disposable runner."
    }
    $Valid = (& $Verifier -Path $SignedCopy -ExpectedState valid) | ConvertFrom-Json

    Copy-Item -LiteralPath $SignedCopy -Destination $TamperedCopy
    $Bytes = [IO.File]::ReadAllBytes($TamperedCopy)
    if ($Bytes.Length -lt 4097) { throw "Executable fixture is too small for a bounded tamper test." }
    $Bytes[4096] = $Bytes[4096] -bxor 0x01
    [IO.File]::WriteAllBytes($TamperedCopy, $Bytes)
    $Tampered = (& $Verifier -Path $TamperedCopy -ExpectedState invalid-tampered) | ConvertFrom-Json

    Remove-Item -LiteralPath "Cert:\CurrentUser\TrustedPublisher\$($ImportedPublisher.Thumbprint)" -ErrorAction SilentlyContinue
    $ImportedPublisher = $null
    Remove-Item -LiteralPath "Cert:\CurrentUser\Root\$($ImportedRoot.Thumbprint)" -ErrorAction SilentlyContinue
    $ImportedRoot = $null
    $UntrustedCertificate = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject "CN=DevPulse Untrusted Ephemeral TEST Certificate Only" `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -KeyExportPolicy NonExportable `
        -NotAfter (Get-Date).AddDays(1)
    Copy-Item -LiteralPath $UnsignedExecutable -Destination $UntrustedCopy
    $UntrustedSigningResult = Set-AuthenticodeSignature -LiteralPath $UntrustedCopy -Certificate $UntrustedCertificate -HashAlgorithm SHA256
    if ($UntrustedSigningResult.Status -eq "NotSigned" -or $null -eq $UntrustedSigningResult.SignerCertificate) {
        throw "The untrusted TEST signature was not embedded."
    }
    $Untrusted = (& $Verifier -Path $UntrustedCopy -ExpectedState untrusted) | ConvertFrom-Json

    [ordered]@{
        schemaVersion = 1
        status = "passed"
        testCertificate = "ephemeral self-signed TEST certificate; non-exportable key; runner-only"
        productionAssurance = $false
        cases = [ordered]@{
            unsigned = $Unsigned.verificationState
            validEphemeralTestSignature = $Valid.verificationState
            tampered = $Tampered.verificationState
            untrusted = $Untrusted.verificationState
        }
        certificateExpiryClassificationAvailable = $true
        expiredCertificateCaseExercised = $false
        privateKeyExported = $false
        privateKeyPersistedAsWorkflowArtifact = $false
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding utf8
}
finally {
    if ($null -ne $ImportedPublisher) {
        Remove-Item -LiteralPath "Cert:\CurrentUser\TrustedPublisher\$($ImportedPublisher.Thumbprint)" -ErrorAction SilentlyContinue
    }
    if ($null -ne $ImportedRoot) {
        Remove-Item -LiteralPath "Cert:\CurrentUser\Root\$($ImportedRoot.Thumbprint)" -ErrorAction SilentlyContinue
    }
    if ($null -ne $Certificate) {
        Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($Certificate.Thumbprint)" -ErrorAction SilentlyContinue
    }
    if ($null -ne $UntrustedCertificate) {
        Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($UntrustedCertificate.Thumbprint)" -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $TestRoot -PathType Container) {
        $ResolvedTestRoot = (Resolve-Path -LiteralPath $TestRoot).Path
        if ([IO.Path]::GetFullPath($ResolvedTestRoot) -notlike "$RunnerTemp\*") {
            throw "Refusing to clean an unvalidated signing-test directory."
        }
        Remove-Item -LiteralPath $ResolvedTestRoot -Recurse -Force
    }
}
