<#
.SYNOPSIS
Intune Windows App Goverance Reporting Script
Identifies imported apps by description, checks assignments and age, 
and flags apps older than 60 days with assignment for review. 

.PARAMETER DescriptionKeyword
The description keyword to search for in app descriptions (e.g., "Intune Managed App").

.PARAMETER ExportCSV 
Switch to automatically export results to CSV without propmpting. 

.EXAMPLE
.\AppNotes_Search.ps1 -DescriptionKeyword "Intune Managed App" -ExportCSV
.\AppNotes_Search.ps1 -DescriptionKeyword "AutoImport" -StaleDaysThreshold 30 -ExportCSV
#>

[CmdletBinding()]
param (
    [string]$DescriptionKeyword,

    [int]$StaleDaysThreshold = 60,

    [switch]$ExportCSV
)

# ---------------------------------------------------
# Step 0 - Import Microsoft.Graph Module
# ---------------------------------------------------
Import-Module Microsoft.Graph -ErrorAction Stop
# ---------------------------------------------------
# Step 1 - Connect to Microsoft Graph
# ---------------------------------------------------
Write-Host "`n[Info] Connecting to Microsoft Graph..." -ForegroundColor Cyan
Connect-MgGraph -Scopes "DeviceManagementApps.Read.All" -NoWelcome

$context = Get-MgContext
Write-Host "[Info] Connected as: $($context.Account)" -ForegroundColor Cyan

# ---------------------------------------------------
# Step 2 - Pull Windows Apps Only (Server-Side Filter)
# ---------------------------------------------------
Write-Host "`n[Info] Retrieving Windows apps with description containing '$DescriptionKeyword'..." -ForegroundColor Cyan

$uri = "HTTPS://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps?`$filter=isof('microsoft.graph.win32LobApp')"

$response = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
$windowsApps.AddRange($response.value)

# Handle pagination if necessary
while ($response.'@odata.nextLink') {
    $response = Invoke-MgGraphRequest -Method GET -Uri $response.'@odata.nextLink' -OutputType PSObject
    $windowsApps.AddRange($response.value)
}

Write-Host "[Info] Total Windows apps retrieved: $($windowsApps.Count)" -ForegroundColor Cyan

# ---------------------------------------------------
# Step 3 - Filter Apps by Notes Keyword (Client-Side Filter)
# ---------------------------------------------------

Write-Host "`n[Info] Filtering apps with notes containing '$DescriptionKeyword'..." -ForegroundColor Cyan

$notesKeyword = "Notes Key Wording"

$matchedApps = $windowsApps | Where-Object 
    { $_.notes -like "*$notesKeyword*" }

    if(-not $matchedApps -or $matchedApps.Count -eq 0) {
        Write-Host "[Warning] No apps found with '$notesKeywork'. Exiting" -ForegroundColor Yellow
        exit
    }
Write-Host "[Info] Apps matching description keyword: $($matchedApps.Count)" -ForegroundColor Green

# ---------------------------------------------------
# Step 4 - Analyze Assignments and Age
# ---------------------------------------------------
Write-Host "`n[Info] Analyzing app assignments and age..." -ForegroundColor Cyan

$today = Get-Date
$results = [System.Collections.Generic.List[object]]::new()

foreach ($app in $matchedApps) {
    # --- Creation Date ---
    $createdDate = $null
    $daysSinceCreation = $null
    $ageStatus = "Unknown"

    if ($app.createdDateTime) {
        $createdDate = [DateTime]$app.createdDateTime
        $daysSinceCreation = ($today - $createdDate).Days
        $agestatus = if ($daysSinceCreation -ge $StaleDaysThreshold) { "Stale" } else { "Recent" }
    }
    # --- Assignments ---
    try {
        $assignments = Get-MgDeviceAppManagementMobileAppAssignment `
            -MobileAppId $app.id `
            -ErrorAction Stop

    $assignmentCount = $assignments.Count
    $assignmentStatus = if ($assignmentCount -gt 0) { "Assigned" } else { "No Assignment" }

    # Pull group names if assigned
    $assignedGroups = if ($assignmentCount -gt 0) {
        ($assignments | Foreach-Object { $_.Target.AdditionalProperties["groupID"] }) -join ", "
    } else {
        "None"
    }
    } catch {
        $assignmentCount = "0"
        $assignmentStatus = "Error retrieving assignments"
        $assignedGroups = "Error"
    }

    # --- Risk Flag ---
    $riskFlag = if ($agestatus -eq "Stale" -and $assignmentStatus -eq "No Assignment") {
        "*** Review - Stale & Unassigned ***"
    } elseif ($agestatus -eq "Stale" -and $assignmentStatus -eq "Assigned") {
        "Review - Stale but Assigned"
    } elseif ($agestatus -eq "Recent" -and $assignmentStatus -eq "No Assignment") {
        "Stale but Unassigned - Consider Deletion"
    } else {
        "OK"
    }

    $results.Add([PSCustomObject]@{
        AppName = $app.displayName
        AppID = $app.id
        Description = $app.description
        Publisher = $app.publisher
        CreatedDate = if ($createdDate) { $createdDate.ToString("yyyy-MM-dd") } else { "N/A" }
        DaysSinceCreation = $daysSinceCreation
        AgeStatus = $ageStatus
        AssignmentStatus = $assignmentStatus
        AssignedGroups = $assignedGroups
        RiskFlag = $riskFlag
    })

    # Visual indicator per app 
    $color = switch ($riskFlag) {
        "*** Review - Stale & Unassigned ***" { "Red" }
        "Review - Stale but Assigned" { "Yellow" }
        "Stale but Unassigned - Consider Deletion" { "Magenta" }
        default { "Green" }
    }

    $createdDateStr = if ($createdDate) { $createdDate.ToString("yyyy-MM-dd") } else { '' }

    Write-Host " [riskFlag] $($app.displayName) | Created: $createdDateStr | Days: $daysSinceCreation | Assignment: $assignmentStatus" -ForegroundColor $color
}

# ---------------------------------------------------
# Step 5 - Summary Report to Console
# ---------------------------------------------------
$reviewCount = ($results | Where-Object { $_.RiskFlag -like "*** Review for Deletion***" }).Count
$assignedStaleCount = ($results | Where-Object { $_.AssignmentStatus -eq "Assigned" }).Count 
$noAssignmentCount = ($results | Where-Object { $_.AssignmentStatus -eq "No Assignment" }).Count

Write-Host "`n=================================" -ForegroundColor Cyan
Write-Host "Summary Report:" -ForegroundColor Cyan
Write-Host "==================================" -ForegroundColor Cyan
Write-Host "Keyword Searched: $DescriptionKeyword" -ForegroundColor Green
Write-Host " Total Matched : $($results.Count)"
Write-Host " Assigned " $assignedStaleCount -ForegroundColor Green
Write-Host " No Assignment : $noAssignCount" -ForegroundColor Yellow
Write-Host " Flagged for Review : $reviewCount" -ForegroundColor Red
Write-Host "==================================" -ForegroundColor Cyan

if ($reviewcount -gt 0) {
    Write-Host "Appls Flagged for Review:" -ForegroundColor Red
    $results | Where-Object { $_.RiskFlag -like "*** Review for Deletion***" } |
    Format-Table AppName, CreatedDate, DaysSinceCreation, AssignmentStatus -AutoSize
}

# ---------------------------------------------------
# Step 6 - Export to CSV if Requested
# ---------------------------------------------------
if ($ExportCSV) {
    $path = ".\IntuneAppAudit_$(Get-Date -Format "yyyyMMdd_HHmmss").csv"
    $results | Export-Csv -Path $path -NoTypeInformation
    Write-Host "[Info] Full report exported to: $path" -ForegroundColor Cyan
} else {
    $export = Read-Host "Do you want to export the full report to CSV? (Y/N)"
    if ($export -eq "Y") {
        $path = ".\IntuneAppAudit_$(Get-Date -Format "yyyyMMdd_HHmmss").csv"
        $results | Export-Csv -Path $path -NoTypeInformation
        Write-Host "[Info] Full report exported to: $path" -ForegroundColor
}
}