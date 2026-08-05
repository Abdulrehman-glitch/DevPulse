param(
    [Parameter(Mandatory = $true)][string]$Baseline,
    [Parameter(Mandatory = $true)][string]$Current,
    [Parameter(Mandatory = $true)][string]$ReportPath,
    [int]$ChannelTolerance = 6,
    [double]$MaximumDifferencePercent = 0.5
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath $Baseline -PathType Leaf) -or -not (Test-Path -LiteralPath $Current -PathType Leaf)) {
    throw "Visual baseline and current image are both required."
}
if ($ChannelTolerance -lt 0 -or $ChannelTolerance -gt 255 -or $MaximumDifferencePercent -lt 0 -or $MaximumDifferencePercent -gt 100) {
    throw "Visual comparison tolerance is outside its bounded range."
}

$BaselineBitmap = [System.Drawing.Bitmap]::new($Baseline)
$CurrentBitmap = [System.Drawing.Bitmap]::new($Current)
try {
    if ($BaselineBitmap.Width -ne $CurrentBitmap.Width -or $BaselineBitmap.Height -ne $CurrentBitmap.Height) {
        throw "Visual baseline and current image dimensions differ."
    }
    $ComparedPixels = [long]$BaselineBitmap.Width * $BaselineBitmap.Height
    $DifferentPixels = 0L
    for ($Y = 0; $Y -lt $BaselineBitmap.Height; $Y++) {
        for ($X = 0; $X -lt $BaselineBitmap.Width; $X++) {
            $Expected = $BaselineBitmap.GetPixel($X, $Y)
            $Actual = $CurrentBitmap.GetPixel($X, $Y)
            if ([Math]::Abs($Expected.R - $Actual.R) -gt $ChannelTolerance -or
                [Math]::Abs($Expected.G - $Actual.G) -gt $ChannelTolerance -or
                [Math]::Abs($Expected.B - $Actual.B) -gt $ChannelTolerance -or
                [Math]::Abs($Expected.A - $Actual.A) -gt $ChannelTolerance) {
                $DifferentPixels++
            }
        }
    }
    $DifferencePercent = if ($ComparedPixels -eq 0) { 0 } else { ($DifferentPixels / $ComparedPixels) * 100 }
    $Report = [ordered]@{
        schemaVersion = 1
        status = if ($DifferencePercent -le $MaximumDifferencePercent) { "passed" } else { "failed" }
        baseline = [IO.Path]::GetFileName($Baseline)
        current = [IO.Path]::GetFileName($Current)
        dimensions = @{ width = $BaselineBitmap.Width; height = $BaselineBitmap.Height }
        channelTolerance = $ChannelTolerance
        maximumDifferencePercent = $MaximumDifferencePercent
        comparedPixels = $ComparedPixels
        differentPixels = $DifferentPixels
        differencePercent = [Math]::Round($DifferencePercent, 5)
        baselineApproval = "explicit baseline input required; this tool never updates or approves a baseline"
    }
    $Parent = Split-Path -Parent $ReportPath
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    $Report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
    if ($Report.status -ne "passed") { throw "Visual difference exceeded the configured tolerance." }
}
finally {
    $BaselineBitmap.Dispose()
    $CurrentBitmap.Dispose()
}
