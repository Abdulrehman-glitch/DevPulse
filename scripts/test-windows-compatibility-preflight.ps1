param(
    [Parameter(Mandatory = $true)][ValidateSet("en-GB", "tr-TR")][string]$Culture,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($env:GITHUB_ACTIONS -ne "true" -or $env:RUNNER_ENVIRONMENT -ne "github-hosted" -or $env:RUNNER_OS -ne "Windows") {
    throw "Windows compatibility preflight is restricted to a disposable GitHub-hosted Windows runner."
}
if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64") { throw "Compatibility qualification requires Windows x64." }

$FixtureRoot = Join-Path $env:RUNNER_TEMP "DevPulse compatibility path 文档 $Culture"
$RunnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$CanonicalFixture = [IO.Path]::GetFullPath($FixtureRoot)
if ($CanonicalFixture -notlike "$RunnerTemp\*") { throw "Compatibility fixture escaped RUNNER_TEMP." }

$OriginalCulture = [Globalization.CultureInfo]::CurrentCulture
$OriginalUiCulture = [Globalization.CultureInfo]::CurrentUICulture
$OriginalDefaultCulture = [Globalization.CultureInfo]::DefaultThreadCurrentCulture
$OriginalDefaultUiCulture = [Globalization.CultureInfo]::DefaultThreadCurrentUICulture
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $FixtureRoot "nested project") | Out-Null
    $UnicodeFile = Join-Path $FixtureRoot "nested project\résumé-東京.json"
    '{"version":"0.3.0-alpha.1","decimal":1.5}' | Set-Content -LiteralPath $UnicodeFile -Encoding utf8
    $FixtureHash = (Get-FileHash -LiteralPath $UnicodeFile -Algorithm SHA256).Hash
    if ((Get-Content -LiteralPath $UnicodeFile -Raw | ConvertFrom-Json).decimal -ne 1.5) {
        throw "Unicode path JSON round-trip failed."
    }

    $SelectedCulture = [Globalization.CultureInfo]::GetCultureInfo($Culture)
    [Globalization.CultureInfo]::DefaultThreadCurrentCulture = $SelectedCulture
    [Globalization.CultureInfo]::DefaultThreadCurrentUICulture = $SelectedCulture
    [Globalization.CultureInfo]::CurrentCulture = $SelectedCulture
    [Globalization.CultureInfo]::CurrentUICulture = $SelectedCulture
    if ([version]::Parse("0.3.0.0").ToString() -ne "0.3.0.0") {
        throw "Version parsing became locale-sensitive."
    }
    $InvariantJson = [ordered]@{ value = 1.5 } | ConvertTo-Json -Compress
    if ($InvariantJson -ne '{"value":1.5}') { throw "JSON serialization became locale-sensitive." }

    $WebViewCandidates = @()
    foreach ($RegistryRoot in @(
        "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients",
        "HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients"
    )) {
        if (-not (Test-Path -LiteralPath $RegistryRoot)) { continue }
        $WebViewCandidates += @(Get-ChildItem -LiteralPath $RegistryRoot -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
        } | Where-Object { $_.name -like "*WebView2*" })
    }
    $WebViewVersion = @($WebViewCandidates | ForEach-Object { [string]$_.pv } | Where-Object { $_ } | Sort-Object -Unique | Select-Object -First 1)
    if ($WebViewVersion.Count -ne 1) { throw "The preinstalled Microsoft WebView2 Runtime was not detected." }

    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
    $Os = Get-CimInstance Win32_OperatingSystem
    [ordered]@{
        schemaVersion = 1
        status = "passed"
        runnerImage = "$env:ImageOS $env:ImageVersion"
        osCaption = [string]$Os.Caption
        osVersion = [string]$Os.Version
        architecture = $env:PROCESSOR_ARCHITECTURE
        cultureUnderTest = $Culture
        pathFixture = "RUNNER_TEMP child containing spaces and non-ASCII characters"
        pathRoundTripSha256 = $FixtureHash
        writableTemporaryFixture = $true
        webView2Detected = $true
        webView2Version = $WebViewVersion[0]
        runnerAccountIsAdministrator = $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        standardUserClaimed = $false
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding utf8
}
finally {
    [Globalization.CultureInfo]::CurrentCulture = $OriginalCulture
    [Globalization.CultureInfo]::CurrentUICulture = $OriginalUiCulture
    [Globalization.CultureInfo]::DefaultThreadCurrentCulture = $OriginalDefaultCulture
    [Globalization.CultureInfo]::DefaultThreadCurrentUICulture = $OriginalDefaultUiCulture
    if (Test-Path -LiteralPath $FixtureRoot -PathType Container) {
        $ResolvedFixture = (Resolve-Path -LiteralPath $FixtureRoot).Path
        if ([IO.Path]::GetFullPath($ResolvedFixture) -notlike "$RunnerTemp\*") {
            throw "Refusing to clean an unvalidated compatibility fixture."
        }
        Remove-Item -LiteralPath $ResolvedFixture -Recurse -Force
    }
}
