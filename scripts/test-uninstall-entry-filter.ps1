$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "lib\uninstall-entry-filter.ps1")

$Cases = @(
    [pscustomobject]@{
        name = "DisplayName present"
        properties = [pscustomobject]@{ DisplayName = "DevPulse" }
        expected = $true
    },
    [pscustomobject]@{
        name = "DisplayName missing"
        properties = [pscustomobject]@{ Publisher = "Example" }
        expected = $false
    },
    [pscustomobject]@{
        name = "DisplayName null"
        properties = [pscustomobject]@{ DisplayName = $null }
        expected = $false
    },
    [pscustomobject]@{
        name = "DisplayName empty"
        properties = [pscustomobject]@{ DisplayName = "" }
        expected = $false
    },
    [pscustomobject]@{
        name = "Different application"
        properties = [pscustomobject]@{ DisplayName = "Another application" }
        expected = $false
    }
)

foreach ($Case in $Cases) {
    $Actual = Test-DevPulseUninstallEntry -Properties $Case.properties
    if ($Actual -ne $Case.expected) {
        throw "$($Case.name) returned '$Actual'; expected '$($Case.expected)'."
    }
}

Write-Output "Uninstall entry filter regression tests passed ($($Cases.Count) cases)."
