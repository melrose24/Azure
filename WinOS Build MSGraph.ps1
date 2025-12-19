# Microsoft Graph API - Get Intune Device Windows OS Build Counts
# Requires Microsoft.Graph.Authentication module

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"

# Define OS build mappings
$osBuildMap = @{
    "22621" = "Windows 11 22H2"
    "22631" = "Windows 11 23H2"
    "26100" = "Windows 11 24H2"
    "26200" = "Windows 11 25H2"
    "19045" = "Windows 10 22H2"
    "19044" = "Windows 10 21H2"
    "19043" = "Windows 10 21H1"
    "19042" = "Windows 10 20H2"
    "18363" = "Windows 10 1909"
    "18362" = "Windows 10 1903"
    "17763" = "Windows 10 1809"
}

# Get all managed devices with OS version
$devices = Get-MgDeviceManagementManagedDevice -All -Property "id,deviceName,operatingSystem,osVersion"

# Filter for Windows devices and group by build number
$windowsDevices = $devices | Where-Object { $_.OperatingSystem -like "Windows*" }

# Group devices by OS version and count
$buildCounts = $windowsDevices | Group-Object -Property osVersion | Select-Object Name, Count | Sort-Object Count -Descending

# Create results with friendly names
$results = @()
foreach ($build in $buildCounts) {
    # Extract build number from version string (e.g., "10.0.22621.1234" -> "22621")
    if ($build.Name -match '\d+\.\d+\.(\d+)') {
        $buildNumber = $Matches[1]
        $friendlyName = if ($osBuildMap.ContainsKey($buildNumber)) {
            $osBuildMap[$buildNumber]
        } else {
            "Unknown Build"
        }
        
        $results += [PSCustomObject]@{
            BuildNumber = $buildNumber
            FullVersion = $build.Name
            OSVersion = $friendlyName
            DeviceCount = $build.Count
        }
    }
}

# Display results
Write-Host "`nWindows Device Count by OS Build:" -ForegroundColor Cyan
Write-Host "=" * 80 -ForegroundColor Cyan
$results | Format-Table -AutoSize

# Identify outdated systems (example: anything older than Windows 11 22H2 or Windows 10 22H2)
Write-Host "`nOutdated Systems (pre-22H2):" -ForegroundColor Yellow
$outdated = $results | Where-Object { 
    $_.BuildNumber -notin @("26100", "26100") 
}
if ($outdated) {
    $outdated | Format-Table -AutoSize
    $totalOutdated = ($outdated | Measure-Object -Property DeviceCount -Sum).Sum
    Write-Host "Total outdated devices: $totalOutdated" -ForegroundColor Red
} else {
    Write-Host "No outdated systems found!" -ForegroundColor Green
}

# Export to CSV
$results | Export-Csv -Path ".\IntuneOSBuildCount.csv" -NoTypeInformation
Write-Host "`nResults exported to IntuneOSBuildCount.csv" -ForegroundColor Green
