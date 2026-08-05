$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DevPulseCaptureNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out Rect rect);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
}
"@

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$QaRoot = Join-Path $Root ".qa-runtime"
$Output = Join-Path $QaRoot "audit\qa-window.png"
$Checkpoint = Join-Path $QaRoot "qa-frontend-checkpoint.json"
New-Item -ItemType Directory -Force -Path (Split-Path $Output) | Out-Null
if (Get-Process -Name "devpulse-desktop" -ErrorAction SilentlyContinue) {
    throw "A DevPulse desktop process is already running; screenshot capture refused."
}
Remove-Item -LiteralPath $Checkpoint -Force -ErrorAction SilentlyContinue
$Candidates = @(Get-ChildItem -LiteralPath (Join-Path $Root "apps\desktop\src-tauri\target\release") -File -Filter "*.exe" | Where-Object {
    $_.VersionInfo.ProductName -eq "DevPulse" -or $_.VersionInfo.FileDescription -eq "DevPulse"
})
if ($Candidates.Count -ne 1) { throw "Could not locate one branded DevPulse release executable." }

$PreviousMode = [Environment]::GetEnvironmentVariable("DEVPULSE_QA_MODE", "Process")
$PreviousRoot = [Environment]::GetEnvironmentVariable("DEVPULSE_QA_ROOT", "Process")
$PreviousAutomation = [Environment]::GetEnvironmentVariable("DEVPULSE_QA_AUTOMATION", "Process")
try {
    $env:DEVPULSE_QA_MODE = "1"
    $env:DEVPULSE_QA_ROOT = $QaRoot
    $env:DEVPULSE_QA_AUTOMATION = "1"
    $Process = Start-Process -FilePath $Candidates[0].FullName -WorkingDirectory $Root -PassThru
}
finally {
    [Environment]::SetEnvironmentVariable("DEVPULSE_QA_MODE", $PreviousMode, "Process")
    [Environment]::SetEnvironmentVariable("DEVPULSE_QA_ROOT", $PreviousRoot, "Process")
    [Environment]::SetEnvironmentVariable("DEVPULSE_QA_AUTOMATION", $PreviousAutomation, "Process")
}

try {
    $Deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        if ($Process.HasExited) { throw "DevPulse exited before screenshot capture." }
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $Deadline)
    if ($Process.MainWindowHandle -eq [IntPtr]::Zero) { throw "DevPulse window did not appear." }
    $CheckpointDeadline = [DateTime]::UtcNow.AddSeconds(120)
    while ([DateTime]::UtcNow -lt $CheckpointDeadline -and
        -not (Test-Path -LiteralPath $Checkpoint)) {
        if ($Process.HasExited) { throw "DevPulse exited before screenshot capture." }
        Start-Sleep -Milliseconds 200
    }
    if (-not (Test-Path -LiteralPath $Checkpoint)) { throw "Frontend screenshot checkpoint timed out." }
    Start-Sleep -Seconds 1
    if ($Process.HasExited) { throw "DevPulse exited before screenshot capture." }
    $Process.Refresh()
    [void][DevPulseCaptureNative]::SetForegroundWindow($Process.MainWindowHandle)
    Start-Sleep -Milliseconds 500
    $Rect = [DevPulseCaptureNative+Rect]::new()
    if (-not [DevPulseCaptureNative]::GetWindowRect($Process.MainWindowHandle, [ref]$Rect)) {
        throw "Could not read the DevPulse window bounds."
    }
    $Width = $Rect.Right - $Rect.Left
    $Height = $Rect.Bottom - $Rect.Top
    if ($Width -lt 980 -or $Height -lt 680) { throw "DevPulse window was below its supported minimum size." }
    $Bitmap = [System.Drawing.Bitmap]::new($Width, $Height)
    $Graphics = [System.Drawing.Graphics]::FromImage($Bitmap)
    try {
        $Graphics.CopyFromScreen($Rect.Left, $Rect.Top, 0, 0, $Bitmap.Size)
        $Bitmap.Save($Output, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $Graphics.Dispose()
        $Bitmap.Dispose()
    }
    Write-Host "QA window captured: $Output"
}
finally {
    if (-not $Process.HasExited) {
        [void][DevPulseCaptureNative]::PostMessage(
            $Process.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero
        )
        [void]$Process.WaitForExit(30000)
    }
    if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force }
}
