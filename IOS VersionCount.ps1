 Connect to Microsoft Graph
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"

# Get all iOS and iPadOS devices
$devices = Get-MgDeviceManagementManagedDevice -All | Where-Object {
    $_.OperatingSystem -eq "iOS" -or $_.OperatingSystem -eq "iPadOS"
}

# Group by OS version and count
$versionCounts = $devices | Group-Object -Property OSVersion |
    Select-Object @{Name="Version"; Expression={$_.Name}},
                  @{Name="Count"; Expression={$_.Count}} |
    Sort-Object Version

# Display results
Write-Host "`niOS/iPadOS Device Count by Version:" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
$versionCounts | Format-Table -AutoSize

# Display total
$totalDevices = ($versionCounts | Measure-Object -Property Count -Sum).Sum
Write-Host "`nTotal iOS/iPadOS Devices: $totalDevices" -ForegroundColor Green

# Optional: Export to CSV
# $versionCounts | Export-Csv -Path "iOS_Version_Counts.csv" -NoTypeInformation
