<#
This script is intended to verify Windows 10 Devices
Filtered on Hybrid Azure AD Joined Devices Only
Activity Windows: Sync Time within 10 days  Get-Date
Hardware Model: Update Model that you want to search On 
Example is VMWare Virtual Platform

#>


Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.ALL" -Nowelcome

# Initialize variables
$URL= "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$select=osVersion,joinType,deviceName,operatingSystem,model,lastSyncdateTime"
$allDevices = @()

# Retrieve all devices paging through results
while ($URL) 
{
    $response = Invoke-MgGraphRequest -Uri $URL
    $allDevices += $response.value
$URL = $response.'@odata.nextLink'
}

# Get the date 10 days ago
$cutoffDate = (Get-Date).AddDays(-10)

# Filter devices per criteria
$filteredDevices = $allDevices | Where-Object 
{
    ($_.operatingSystem -eq "Windows") -and
    ($_.osVersion -match "10.0.1") -and
    ($_.joinType -eq 'hybridAzureADJoined') -and
    ([datetime]$_.lastSyncdateTime -ge $cutoffDate) -and
    ($_.model -eq "VMWare Virtual Platform")
}

# Output filtered devices
Write-Host "`nFiltered Devices: `n"
$filteredDevices | Select-Object deviceName, operatingSystem, osVersion, joinType, model, lastSyncDateTime | Format-Table -AutoSize

# Output count grouped by model
Write-Host "`nCount by Model: `n"
$filteredDevices | Group-Object -Property model | Select-Object Name, Count | Format-Table -AutoSize