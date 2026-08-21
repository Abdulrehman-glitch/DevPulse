$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$DisposableRunner = (
    $env:GITHUB_ACTIONS -eq "true" -and
    $env:RUNNER_ENVIRONMENT -eq "github-hosted" -and
    $env:RUNNER_OS -eq "Windows"
)
if (
    $env:GITHUB_ACTIONS -eq "true" -and
    $env:RUNNER_OS -eq "Windows" -and
    -not $DisposableRunner
) {
    throw "GitHub Actions sidecar QA requires a positively identified GitHub-hosted runner."
}
$QaRoot = if ($DisposableRunner) {
    $SystemDriveRoot = [IO.Path]::GetPathRoot($env:SystemRoot)
    Join-Path $SystemDriveRoot "DevPulse-QA-sidecar smoke 文档-$PID"
} else {
    Join-Path $Root ".qa-runtime\DevPulse-QA-sidecar smoke 文档"
}
$Expected = [System.IO.Path]::GetFullPath($QaRoot)
if ($DisposableRunner) {
    $ExpectedParent = [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($Expected))
    if (
        $ExpectedParent -ne [IO.Path]::GetFullPath($SystemDriveRoot) -or
        [IO.Path]::GetFileName($Expected) -notlike "DevPulse-QA-sidecar*"
    ) {
        throw "Unsafe disposable-runner sidecar smoke-test root."
    }
} elseif ($Expected -notlike "$Root\.qa-runtime\*") {
    throw "Unsafe local sidecar smoke-test root."
}
Write-Host "Packaged sidecar QA boundary: $(if ($DisposableRunner) { 'disposable-system-drive' } else { 'local-repository-sandbox' })."
New-Item -ItemType Directory -Force -Path $QaRoot | Out-Null
$QaRoamingAppData = Join-Path $QaRoot "process-env\roaming"
$QaLocalAppData = Join-Path $QaRoot "process-env\local"
$QaWebView2Data = Join-Path $QaRoot "webview2"
$QaHome = Join-Path $QaRoot "process-env\home"
$QaTemp = Join-Path $QaRoot "process-env\temp"
New-Item -ItemType Directory -Force -Path $QaRoamingAppData, $QaLocalAppData, $QaHome, $QaTemp | Out-Null
$Candidates = @(Get-ChildItem -LiteralPath (Join-Path $Root "apps\desktop\src-tauri\binaries") -File -Filter "*.exe")
if ($Candidates.Count -ne 1) { throw "Expected exactly one packaged sidecar binary." }
$FixtureDirectory = Join-Path $QaRoot "packaged fixture 文档"
New-Item -ItemType Directory -Force -Path $FixtureDirectory | Out-Null
$FixtureExecutable = Join-Path $FixtureDirectory "devpulse local core.exe"
Copy-Item -LiteralPath $Candidates[0].FullName -Destination $FixtureExecutable -Force

$Token = [Guid]::NewGuid().ToString("N") + [Guid]::NewGuid().ToString("N")
$Launch = @{
    protocol_version = 1
    token = $Token
} | ConvertTo-Json -Compress
$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
$StartInfo.FileName = $FixtureExecutable
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
    HOME = $QaHome
    USERPROFILE = $QaHome
    TEMP = $QaTemp
    TMP = $QaTemp
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
        $FailureDetail = "readiness output was empty or exceeded its 512-character bound"
        if ($Process.HasExited) {
            $Process.WaitForExit()
            $Diagnostics = $ErrorRead.Result
            if ($Diagnostics.Contains($Token)) {
                throw "Packaged sidecar failure diagnostics exposed the token."
            }
            $Diagnostics = [regex]::Replace($Diagnostics, '(?i)[0-9a-f]{64}', '[REDACTED]')
            $Diagnostics = [regex]::Replace($Diagnostics, '(?i)(token|secret|password)\s*[:=]\s*\S+', '$1=[REDACTED]')
            $Diagnostics = ($Diagnostics -replace '[\r\n]+', ' ').Trim()
            if ($Diagnostics.Length -gt 1000) { $Diagnostics = $Diagnostics.Substring(0, 1000) }
            $FailureDetail = "process exited with code $($Process.ExitCode)"
            if ($Diagnostics) { $FailureDetail += "; safe stderr: $Diagnostics" }
        }
        throw "Packaged sidecar returned an invalid readiness frame ($FailureDetail)."
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
    if ($DisposableRunner -and (Test-Path -LiteralPath $QaRoot -PathType Container)) {
        $CleanupTarget = (Resolve-Path -LiteralPath $QaRoot).Path
        if (
            [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($CleanupTarget)) -ne [IO.Path]::GetFullPath($SystemDriveRoot) -or
            [IO.Path]::GetFileName($CleanupTarget) -notlike "DevPulse-QA-sidecar*" -or
            (Get-Item -LiteralPath $CleanupTarget -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -or
            (Test-Path -LiteralPath (Join-Path $CleanupTarget ".git"))
        ) {
            throw "Refusing to clean an unvalidated disposable-runner sidecar fixture."
        }
        Remove-Item -LiteralPath $CleanupTarget -Recurse -Force
    }
}
