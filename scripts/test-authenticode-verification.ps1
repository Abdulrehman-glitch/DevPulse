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

function Find-SignTool {
    $WindowsKits = Join-Path ([Environment]::GetFolderPath("ProgramFilesX86")) "Windows Kits\10\bin"
    $Candidates = @(
        if (Test-Path -LiteralPath $WindowsKits -PathType Container) {
            Get-ChildItem -LiteralPath $WindowsKits -Recurse -File -Filter "signtool.exe" |
                Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
                Sort-Object FullName -Descending
        }
    )
    if ($Candidates.Count -eq 0) { throw "The standard runner did not provide the Windows SDK signing tool." }
    return $Candidates[0].FullName
}

function Invoke-BoundedTool {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 30
    )

    $StartInfo = [Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = $FilePath
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    foreach ($Argument in $Arguments) { [void]$StartInfo.ArgumentList.Add($Argument) }
    $Process = [Diagnostics.Process]::new()
    $Process.StartInfo = $StartInfo
    $Started = $false
    try {
        if (-not $Process.Start()) { throw "A signing-test child process could not start." }
        $Started = $true
        $OutputRead = $Process.StandardOutput.ReadToEndAsync()
        $ErrorRead = $Process.StandardError.ReadToEndAsync()
        if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
            $Process.Kill($true)
            $Process.WaitForExit()
            throw "A signing-test child process exceeded its $TimeoutSeconds-second bound."
        }
        $Process.WaitForExit()
        [void]$OutputRead.Result
        [void]$ErrorRead.Result
        if ($Process.ExitCode -ne 0) {
            throw "A signing-test child process failed with exit code $($Process.ExitCode)."
        }
    }
    finally {
        if ($Started -and -not $Process.HasExited) {
            $Process.Kill($true)
            $Process.WaitForExit()
        }
        $Process.Dispose()
    }
}

function Add-EphemeralTestTrust {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Root", "TrustedPublisher")][string]$StoreName,
        [Parameter(Mandatory = $true)]$Certificate
    )
    $Store = [Security.Cryptography.X509Certificates.X509Store]::new(
        $StoreName,
        [Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
    )
    try {
        $Store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $Store.Add($Certificate)
    }
    finally {
        $Store.Close()
        $Store.Dispose()
    }
}

function Remove-EphemeralTestTrust {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Root", "TrustedPublisher")][string]$StoreName,
        [Parameter(Mandatory = $true)]$Certificate
    )
    $Store = [Security.Cryptography.X509Certificates.X509Store]::new(
        $StoreName,
        [Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
    )
    try {
        $Store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $Store.Remove($Certificate)
    }
    finally {
        $Store.Close()
        $Store.Dispose()
    }
}

$Verifier = Join-Path $PSScriptRoot "verify-authenticode.ps1"
$SignTool = Find-SignTool
$TestRoot = Join-Path $env:RUNNER_TEMP "DevPulse-Authenticode-ephemeral-TEST-$PID"
$RunnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$CanonicalTestRoot = [IO.Path]::GetFullPath($TestRoot)
if ($CanonicalTestRoot -notlike "$RunnerTemp\*") { throw "Ephemeral signing test escaped RUNNER_TEMP." }

$Certificate = $null
$PublicOnlyCertificate = $null
$UntrustedCertificate = $null
$RootInstalled = $false
$TrustedPublisherInstalled = $false
try {
    New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null
    $UnsignedCopy = Join-Path $TestRoot "unsigned-fixture.exe"
    $SignedCopy = Join-Path $TestRoot "signed-ephemeral-TEST-fixture.exe"
    $UntrustedCopy = Join-Path $TestRoot "untrusted-ephemeral-TEST-fixture.exe"
    $TamperedCopy = Join-Path $TestRoot "tampered-fixture.exe"
    $PublicCertificate = Join-Path $TestRoot "ephemeral-public-TEST-only.cer"
    Copy-Item -LiteralPath $UnsignedExecutable -Destination $UnsignedCopy

    Write-Host "Authenticode TEST phase 1/6: classify unsigned fixture."
    $Unsigned = (& $Verifier -Path $UnsignedCopy -ExpectedState unsigned) | ConvertFrom-Json

    Write-Host "Authenticode TEST phase 2/6: create non-exportable ephemeral certificate."
    $Certificate = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject "CN=DevPulse Ephemeral TEST Certificate Only" `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -HashAlgorithm SHA256 `
        -KeyExportPolicy NonExportable `
        -NotAfter (Get-Date).AddDays(1)
    Export-Certificate -Cert $Certificate -FilePath $PublicCertificate -Force | Out-Null
    $PublicOnlyCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($PublicCertificate)
    # Authenticode chain validation requires a trust anchor. TrustedPeople alone
    # still produces NotTrusted on hosted Windows, so install only the public
    # TEST certificate in this disposable runner's CurrentUser Root store.
    Add-EphemeralTestTrust -StoreName "Root" -Certificate $PublicOnlyCertificate
    $RootInstalled = $true
    Add-EphemeralTestTrust -StoreName "TrustedPublisher" -Certificate $PublicOnlyCertificate
    $TrustedPublisherInstalled = $true

    Write-Host "Authenticode TEST phase 3/6: sign and validate trusted TEST fixture."
    Copy-Item -LiteralPath $UnsignedExecutable -Destination $SignedCopy
    Invoke-BoundedTool -FilePath $SignTool -Arguments @(
        "sign", "/fd", "SHA256", "/sha1", $Certificate.Thumbprint, "/s", "My", $SignedCopy
    )
    $Valid = (& $Verifier -Path $SignedCopy -ExpectedState valid) | ConvertFrom-Json

    Write-Host "Authenticode TEST phase 4/6: detect a tampered TEST fixture."
    Copy-Item -LiteralPath $SignedCopy -Destination $TamperedCopy
    $Bytes = [IO.File]::ReadAllBytes($TamperedCopy)
    if ($Bytes.Length -lt 4097) { throw "Executable fixture is too small for a bounded tamper test." }
    $Bytes[4096] = $Bytes[4096] -bxor 0x01
    [IO.File]::WriteAllBytes($TamperedCopy, $Bytes)
    $Tampered = (& $Verifier -Path $TamperedCopy -ExpectedState invalid-tampered) | ConvertFrom-Json

    Write-Host "Authenticode TEST phase 5/6: remove temporary trust and classify untrusted signature."
    Remove-EphemeralTestTrust -StoreName "TrustedPublisher" -Certificate $PublicOnlyCertificate
    $TrustedPublisherInstalled = $false
    Remove-EphemeralTestTrust -StoreName "Root" -Certificate $PublicOnlyCertificate
    $RootInstalled = $false
    $UntrustedCertificate = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject "CN=DevPulse Untrusted Ephemeral TEST Certificate Only" `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -HashAlgorithm SHA256 `
        -KeyExportPolicy NonExportable `
        -NotAfter (Get-Date).AddDays(1)
    Copy-Item -LiteralPath $UnsignedExecutable -Destination $UntrustedCopy
    Invoke-BoundedTool -FilePath $SignTool -Arguments @(
        "sign", "/fd", "SHA256", "/sha1", $UntrustedCertificate.Thumbprint, "/s", "My", $UntrustedCopy
    )
    $Untrusted = (& $Verifier -Path $UntrustedCopy -ExpectedState untrusted) | ConvertFrom-Json

    Write-Host "Authenticode TEST phase 6/6: record non-production verification evidence."
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
    if ($TrustedPublisherInstalled -and $null -ne $PublicOnlyCertificate) {
        try { Remove-EphemeralTestTrust -StoreName "TrustedPublisher" -Certificate $PublicOnlyCertificate } catch { Write-Warning "Disposable TEST publisher cleanup did not complete before runner disposal." }
    }
    if ($RootInstalled -and $null -ne $PublicOnlyCertificate) {
        try { Remove-EphemeralTestTrust -StoreName "Root" -Certificate $PublicOnlyCertificate } catch { Write-Warning "Disposable TEST root cleanup did not complete before runner disposal." }
    }
    if ($null -ne $Certificate) {
        Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($Certificate.Thumbprint)" -ErrorAction SilentlyContinue
    }
    if ($null -ne $UntrustedCertificate) {
        Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($UntrustedCertificate.Thumbprint)" -ErrorAction SilentlyContinue
    }
    if ($null -ne $PublicOnlyCertificate) { $PublicOnlyCertificate.Dispose() }
    if (Test-Path -LiteralPath $TestRoot -PathType Container) {
        $ResolvedTestRoot = (Resolve-Path -LiteralPath $TestRoot).Path
        if ([IO.Path]::GetFullPath($ResolvedTestRoot) -notlike "$RunnerTemp\*") {
            throw "Refusing to clean an unvalidated signing-test directory."
        }
        Remove-Item -LiteralPath $ResolvedTestRoot -Recurse -Force
    }
}
