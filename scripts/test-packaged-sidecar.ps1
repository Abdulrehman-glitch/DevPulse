$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$QaRoot = Join-Path $Root ".qa-runtime\DevPulse-QA-sidecar-smoke"
$Expected = [System.IO.Path]::GetFullPath($QaRoot)
if ($Expected -notlike "$Root\.qa-runtime\*") { throw "Unsafe sidecar smoke-test root." }
New-Item -ItemType Directory -Force -Path $QaRoot | Out-Null
$QaRoamingAppData = Join-Path $QaRoot "process-env\roaming"
$QaLocalAppData = Join-Path $QaRoot "process-env\local"
$QaWebView2Data = Join-Path $QaRoot "webview2"
$Candidates = @(Get-ChildItem -LiteralPath (Join-Path $Root "apps\desktop\src-tauri\binaries") -File -Filter "*.exe")
if ($Candidates.Count -ne 1) { throw "Expected exactly one packaged sidecar binary." }

$Token = [Guid]::NewGuid().ToString("N") + [Guid]::NewGuid().ToString("N")
$Launch = @{
    protocol_version = 1
    token = $Token
} | ConvertTo-Json -Compress
$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
$StartInfo.FileName = $Candidates[0].FullName
$StartInfo.WorkingDirectory = $Root
$StartInfo.UseShellExecute = $false
$StartInfo.CreateNoWindow = $true
$StartInfo.RedirectStandardInput = $true
$StartInfo.RedirectStandardOutput = $true
$StartInfo.RedirectStandardError = $true
$StartInfo.Arguments = "--data-dir `"$QaRoot`" --qa-mode"
foreach ($Entry in @{
    DEVPULSE_QA_MODE = "1"
    DEVPULSE_INSTALL_QA = "0"
    DEVPULSE_QA_AUTOMATION = "0"
    DEVPULSE_QA_FAIL_START = "0"
    DEVPULSE_QA_ROOT = $QaRoot
    DEVPULSE_DATA_DIR = $QaRoot
    APPDATA = $QaRoamingAppData
    LOCALAPPDATA = $QaLocalAppData
    WEBVIEW2_USER_DATA_FOLDER = $QaWebView2Data
}.GetEnumerator()) {
    $StartInfo.Environment[$Entry.Key] = [string]$Entry.Value
}
if ($StartInfo.Arguments.Contains($Token)) { throw "The token entered the child command line." }
if (@($StartInfo.Environment.Values | Where-Object { $_ -eq $Token }).Count -ne 0) {
    throw "The token entered the child environment."
}

$Process = [System.Diagnostics.Process]::new()
$Process.StartInfo = $StartInfo
try {
    if (-not $Process.Start()) { throw "Could not start the packaged sidecar." }
    $ErrorRead = $Process.StandardError.ReadToEndAsync()
    $Process.StandardInput.WriteLine("DEVPULSE_LAUNCH $Launch")
    $Process.StandardInput.Flush()
    $Process.StandardInput.Close()

    $ReadyRead = $Process.StandardOutput.ReadLineAsync()
    if (-not $ReadyRead.Wait([TimeSpan]::FromSeconds(30))) {
        throw "Packaged sidecar readiness timed out."
    }
    $ReadyLine = $ReadyRead.Result
    if ([string]::IsNullOrWhiteSpace($ReadyLine) -or $ReadyLine.Length -gt 512) {
        throw "Packaged sidecar returned an invalid readiness frame."
    }
    if ($ReadyLine.Contains($Token) -or $ReadyLine -match '(?i)token') {
        throw "Packaged sidecar readiness exposed the token."
    }
    if (-not $ReadyLine.StartsWith("DEVPULSE_READY ")) {
        throw "Packaged sidecar returned an invalid readiness frame type."
    }
    $Ready = $ReadyLine.Substring("DEVPULSE_READY ".Length) | ConvertFrom-Json
    $ReadyProperties = @($Ready.PSObject.Properties.Name | Sort-Object)
    $ExpectedProperties = @("instance_id", "pid", "port", "protocol_version", "status") | Sort-Object
    if (@(Compare-Object $ReadyProperties $ExpectedProperties).Count -ne 0 -or
        $Ready.protocol_version -ne 1 -or $Ready.status -ne "ready" -or
        $Ready.port -lt 1 -or $Ready.port -gt 65535 -or $Ready.pid -lt 1 -or
        $Ready.instance_id -notmatch '^[0-9a-f]{32}$') {
        throw "Packaged sidecar returned invalid readiness data."
    }
    $Address = "http://127.0.0.1:$($Ready.port)"
    try {
        Invoke-WebRequest -Uri "$Address/health" -UseBasicParsing -TimeoutSec 5 | Out-Null
        throw "Unauthenticated health unexpectedly succeeded."
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 401) { throw }
    }
    $Headers = @{ "X-DevPulse-Token" = $Token }
    $Health = Invoke-RestMethod -Uri "$Address/health" -Headers $Headers -TimeoutSec 5
    if ($Health.status -ne "ok" -or -not $Health.qa_mode) { throw "Authenticated QA health failed." }
    $PathReportPath = Join-Path $QaRoot "local-core-path-report.json"
    if (-not (Test-Path -LiteralPath $PathReportPath -PathType Leaf)) {
        throw "Packaged sidecar did not emit its QA path report."
    }
    $PathReport = Get-Content -LiteralPath $PathReportPath -Raw | ConvertFrom-Json
    if (-not $PathReport.allWritablePathsUnderQaRoot -or -not $PathReport.environmentMatchesCanonicalPlan) {
        throw "Packaged sidecar did not keep every writable path inside its canonical QA root."
    }
    if (@(Get-ChildItem -LiteralPath $QaRoot -Recurse -File -Filter "*handshake*.json").Count -ne 0) {
        throw "Packaged sidecar produced an obsolete disk handshake."
    }
    Invoke-RestMethod -Uri "$Address/internal/shutdown" -Method Post -Headers $Headers -TimeoutSec 5 | Out-Null
    if (-not $Process.WaitForExit(15000)) { throw "Packaged sidecar did not shut down promptly." }
    if ($Process.ExitCode -ne 0) { throw "Packaged sidecar exited with a non-zero code." }
    $Diagnostics = $ErrorRead.Result
    if ($Diagnostics.Contains($Token)) { throw "Packaged sidecar diagnostics exposed the token." }
    $LogFiles = @(Get-ChildItem -LiteralPath $QaRoot -Recurse -File -Filter "*.log*")
    foreach ($LogFile in $LogFiles) {
        if ((Get-Content -LiteralPath $LogFile.FullName -Raw).Contains($Token)) {
            throw "Packaged sidecar logs exposed the token."
        }
    }
    Write-Host "Packaged sidecar stdin launch, authenticated health, and shutdown passed."
}
finally {
    if ($null -ne $Process -and -not $Process.HasExited) {
        $Process.Kill($true)
        $Process.WaitForExit()
    }
    $Token = $null
}
