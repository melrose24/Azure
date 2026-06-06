<#
.SYNOPSIS
    AppsTiedToGroup.ps1 - Intune App Assignment Validator

.NOTES
    DISCLAIMER:
    This script is provided "AS IS" without any warranties, guarantees, or 
    representations of any kind. Automated changes or API queries in production 
    environments carry inherent risks. 

    Please test thoroughly in a staging or non-production environment before 
    running at scale. The author assumes no liability or responsibility for 
    any damages, data loss, or unexpected behavior caused by using this code.

# Change File to .PS1
# Reads FIRST column (column A) from CSV (header not required)
# Outputs: Name, Status, AssignedToGroup (yes/no), DepLoyedToALDevices (yes/no)
# Neeed to update CSVFolder and File..
# If looking for another Group, just change it..
#>

$CsvFolder = "~/Documents/AppLications/"
$CsvFile = "AppName, csv"
$csvPath = Join-Path $CsvFolder $CsvFile

if (-not (Test-Path $csvPath)) { throw "CSV not found: $csvPath"}

$GroupDisplayName = "GroupName"

# Comment out the following line if you have already connected to Graph in this session and want to reuse the connection
Import-Module Microsoft.Graph

# Connect to Graph with required scopes (will prompt for login if not already connected)
Connect-MgGraph -Scopes "DeviceManagementApps.Read.All Group.Read.ALL" | Out-Null

# Detect delimiter from first non-empty line
$firstNonEmpty = (Get-Content -Path $csvPath | Where-Object { $_.Trim() -ne ""} | Select-Object -First 1)
if (-not $firstNonEmpty) { throw "CSV appears to be empty: $csvPath" }

$commaCount = ([regex]::Matches($firstNonEmpty, ",")).Count
$semiCount = ([regex]::Matches($firstNonEmpty, ";")).Count
$Delimiter = if ($semiCount -gt $commaCount) { ";"} else { "," }
Write-Host "Using delimiter: '$Delimiter'"

# Read first column values (no header required)
$appNames = foreach ($line in (Get-Content -Path $csvPath)) {
    If ([string]::IsNullOrWhiteSpace($line)) { continue }
    $first = ($line -split [regex]::Escape($Delimiter), 2)[0].Trim().Trim('"')
    if (-not [string]::IsNullOrWhiteSpace($first)) { $first }
}

if (-not $appNames -or $appNames.Count -eq 0) {
    throw "No app names found in first column: $csvPath"
}

# Resolve group id once
$escapedGroup = $GroupDisplayName.Replace("'", "''")
$groupUri = "/beta/groups?`$filter=displayName eq '$escapedGroup'&`$select=id,displayName&`$top=1"
$groupId = $null
try {
  $g = Invoke-MgGraphRequest -Method GET -Uri $groupUri
  if ($g.value -and $g.value.Count -gt 0) {
  $groupId = $g.value[0].id
} else {
   throw "Group not found in AAD: '$GroupDisplayName'"
 }
} catch {
 throw "Failed to resolve group '$GroupDisplayName': $($_.Exception.Message)"
}

$out = New-Object System.Collections.Generic.List[object]

foreach ($appName in $appNames) {
$escapedName = $appName.Replace("'", "''")

# Find app id
$appUri = "/beta/deviceAppManagement/mobileApps?`$filter=displayName eq '$escapedName'&`$top=1&`$select=id, displayName"
$status = "not found"
$assignedToGroup = ""
$deployedToAllDevices = ""

try {
  $resp = Invoke-MgGraphRequest -Method GET -Uri $appUri
  if ($resp.value -and $resp.value.Count -gt 0) {
     $status = "found"
     $appId = $resp.value[0].id

# defaults (only evaluated if app is found)
$isAssignedToGroup = $false
$isDeployedToAllDevices = $false

# Check assignments
$assignUri= "/beta/deviceAppManagement/mobileApps/$appId/assignments?`$select=id,target"
$assignResp = Invoke-MgGraphRequest -Method GET -Uri $assignUri

foreach ($a in @($assignResp.value)) {
  $target = $a.target
  if (-not $target) { continue }

# Group target?
if ($target.groupId -and ($target.groupId -eq $groupId)) {
$isAssignedToGroup = $true
}

# All devices target?
# Graph typically returns: '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget
$odataType = $null
try { $odataType = $target.'@odata.type' } catch {}
if (-not $odataType) {
 try { $odataType = $target.'odata.type' } catch {}
}

if ($odataType -and ($odataType -match 'alldevicesAssignmentTarget')) {
    $isDeployedToAllDevices = $true
}

if ($isAssignedToGroup -or $isDeployedToAllDevices) {
    # IF you want to stop early oce both are found, uncomment: 
    # if ($isAssignedToGroup -and $isDeployedToAllDevices) { break }
}
}

$assignedToGroup = if ($isAssignedToGroup) { "yes" } else { "no" }
$deployedToAllDevices = if ($isDeployedToAllDevices) { "yes" } else { "no" }
 }
}

catch {
   Write-Warning "Graph lookup failed for '$appName': $($_.Exception.Message)"
$status = "not found"
$assignedToGroup = ""
$deployedToAllDevices = ""
}

write-Host "$appName => $status, AssignedToGroup=$assignedToGroup, DeployedToAllDevices=$deployedToAllDevices"
 
$out.Add([pscustomobject]@{
Name = $appName
Status = $status
AssignedToGroup = $assignedToGroup
DeployedToAllDevices = $deployedToAllDevices
 })
}

$outPath = Join-Path $CsvFolder ("Results_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$out | Export-Csv -Path $outPath -NoTypeInformation
Write-Host "Results exported to: $outPath"
