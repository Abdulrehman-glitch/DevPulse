function Test-DevPulseUninstallEntry {
    param(
        [AllowNull()]$Properties
    )

    if ($null -eq $Properties) { return $false }

    $DisplayNameProperty = $Properties.PSObject.Properties["DisplayName"]
    if ($null -eq $DisplayNameProperty) { return $false }

    $DisplayName = [string]$DisplayNameProperty.Value
    if ([string]::IsNullOrWhiteSpace($DisplayName)) { return $false }

    return $DisplayName -eq "DevPulse"
}
