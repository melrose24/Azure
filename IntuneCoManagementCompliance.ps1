<#PSSScriptInfo

.Notes 
This script requires the following Microsoft Graph PowerShell SDK Modules
- Microsoft.Graph.Authentication

This script requires login with elevated persmission to Azure AD

Required Microsoft Graph Scopes: 
- User.Read.All
- Device.Read.All
- Group.Read.All
- DeviceManagementManagedDevices.Read.All

Script has been tested in Powershell version 7.5.1

.LINK
HTTPS://learn.microsoft.com/en-us/graph/api/resources/users?view=graph-rest-beta

.LINK
HTTPS://learn.microsoft.com/en-us/graph/aad-advanced-queries?tabs=http

.LINK
HTTPS://learn.microsoft.com/en-us/powershell/microsoftgraph/overview?view=graph-powershell-beta

#>

Function Connect {
 #This will pop a browser window to authenticate; this is for a PS7 session with Delegated auth
 $scopes = @("User.Read.All", "Device.Read.All", "Group.Read.All", "DeviceManagementManagedDevices.Read.All")

 try {
    Write-Host "Connecting to Microsoft Graph; login with the desired account via browser" -ForegroundColor Cyan
    # Defining all available scopes to ensure proper permission to query / modify Intune
    Connect-MgGraph -Scopes $scopes -ContextScope Process    
    }
    Catch {
        Write-Host "Failed to connect to Graph... terminating" -ForegroundColor Red
        Write-Warning $_.Exception.Message
        exit 1
    }
                }

# Call Graph API to query Windows devices in Intune

Function Get-IntuneReport {
    #IN this case, looking for Windows Devices (operatingSystem eq Windows) and devices in an unsersire compliance state (Example 'noncompliant' or 'ingraceperiod')
    $uri = "https://graph.microsoft.com/beta/devicemanagement/managedDevices?`$filter=(operatingSystem eq 'Windows') and (complianceState eq 'noncompliant' or 'inGracePeriod' or complianceState eq 'configManager')&`$select=deviceName,OSVersion,emailAddress,lastSyncDateTime,ComplianceState,deviceEnrollmentType,azureAddeviceID,azureADDeviceID,configurationManagerClientHealthState,configurationManagerClientEnabledFeatures"

    Write-Host ""
    Write-Host "Generating Intune Non-Compliant device report.." -NoNewline

    $IntuneReport = @()
    #Make the Graph API call to request the report 
    try {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri
        $IntuneReport += $response.value
        # This is goign to be paginated, need to keep calling for all results
        if ($response.Keys -contains '@odata.nextlink') {
            do {
                $uri = $response.'@odata.nextlink'
                $response = Invoke-MgGraphRequest -Method GET -Uri $uri
                $IntuneReport += $response.value
                Write-Host "..." -NoNewline
            }
            until ($response.Keys -notcontains '@odata.nextlink')
        }
    }
    catch {
        # Rerun an error (value 1)
        Write-Host "Failed to Call $uri" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Return 1
    }
    Write-Host "Completed" -ForegroundColor Green

    return $IntuneReport
}

<#
Perform "GET" calls against Graph / Entra ID to retrieve device info and additional details not in the Intune Report
Get-EnrichedData function takes a single app instance (item) and enriches that object with more details. then returns that enriched object
#>

Function Get-EnrichedData 
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        $item
    )

    # Define  an empty hashtable to store enriched data
    $enrichedItem = @{}

    # Retrieve additional devie/user attributes from Enra Graph batch API
        $uri = "https://graph.microsoft.com/beta/`$batch"

    # Adding objects to hashtable to convert to json
    $body = @{}
    $body.Add('requests', @())
    $body.requests += @{id='1'; method='GET'; url="users/$($item.emailAddress)?`$select=onPremisesSamAccountName,jobTitle,department"}
    $body.requests += @{id='2'; method='GET'; url="users/$($item.emailAddress)/ownedDevices?`$select=displayName,operatingSystem,isCompliant,accountEnabled,approximateLastSignInDateTime"}
    $json = $body | ConvertFrom-Json -Depth 10 #id depth needed

    try {
        $batchResponse = (Invoke-MgRestMethod -Method POST -Uri $uri -Body $json).response.body 
    }
    catch {
        Write-Host "Failed to retrieve Entra ID user/device details for $($item.emailAddress)" -ForegroundColor Red
        #Create empty hashtable to evaluate
        $batchResponse = @{}
    }

    # Parse any additional active devices the user might have
    $otherActiveDevices = $null 
    foreach ($device in $batchResponse.value) {
        if (($device.operatingSystem -eq 'Windows') -and ($device.approximateLastSignInDateTime -gt (Get-Date).AddDays(-7)) -and ($device.displayName -ne $item.deviceName) -and ($device.accountEnabled -eq $true)) {
            switch ($device.isCompliant) {
                true { $compliance = 'Compliant' }
                false { $compliance = 'NotCompliant' }
            }
            if ($otherActiveDevices) {
                $otherActiveDevices += ';'
            }
                $otherActiveDevices += "$($device.displayName) |$compliance|$($device.approximateLastSignInDateTime)"
        }
    }

    # Compile all of the attributes we want to capture in the enriched report
    $enrichedItem.Add('DeviceName', $item.deviceName)
    $enrichedItem.Add('UserMail', $item.emailAddress)
    switch ($batchResponse.onPremisesSamAccountName) {
        $null {$enrichedItem.Add('UserAlias', ((($item.emailAddress).Split('@')[0]).Split(".")[(($item.emailAddress).Split('@')[0]).Split(".").Count -1]).toUpper()) } 
    Default { $enrichedItem.Add('UserAlias', $batchResponse.onPremisesSamAccountName) }
    }

    switch ($batchResponse.jobTitle) {
        $null { $enrichedItem.Add('UserJobTitle', 'N/A')}
        Default { $enrichedItem.Add('UserJobTitle', $batchResponse.jobTitle)}
    }

    switch ($batchResponse.department) {
    $null { $enrichedItem.Add('UserDepartment', 'N/A') }
    Default { $enrichedItem.Add('UserDepartment', $batchResponse.department) }
    }

    if ($enrichedItem.UserMail -like "term*.*") {
        $enrichedItem.UserMail = "Terminated"
        $enrichedItem.UserAlias = 'N/A'
        $enrichedItem.UserJobTitle = 'N/A'
        $enrichedItem.UserDepartment = 'N/A'
    }

  if ($enrichedItem.UserMail -like $null) {
        $enrichedItem.UserMail = 'N/A'
        $enrichedItem.UserAlias = 'N/A'
        $enrichedItem.UserJobTitle = 'N/A'
        $enrichedItem.UserDepartment = 'N/A'
    }
    $enrichedItem.Add('OSVersion', $item.OSVersion)
    $enrichedItem.Add('IntuneLastCheckIn', $item.lastSyncDateTime)
    try {
        $enrichedItem.Add('MeMCMLastCheckin', $item.configurationManagerClientHealthState.lastSyncDateTime)
        if ($null -eq $enrichedItem.MeMCMLastCheckin -or $enrichedItem.MeMCMLastCheckin -eq (Get-Date -Date "Monday. January 1, 0001 12:00:00 AM")) {
            $enrichedItem.MeMCMLastCheckin = 'N/A'
        }
    }
    catch {
        $enrichedItem.Add('MEMCMLastCheckin', 'N/A')
    }
    $enrichedItem.Add('ComplianceStatus', $item.complianceState)
    if ($enrichedItem.ComplianceStatus -eq "configManager") {
        $enrichedItem.ComplianceStatus = 'N/A'
    }
    
    $enrichedItem.Add('IsCoManaged', $item.deviceEnrollmentType)
    if ($enrichedItem.IsComanaged -eq "windowsCoMnagement") {
        $enrichedItem.IsComanaged = $true
    }
    else {
        $enrichedItem.IsComanaged = $false
    }
    try {
        $enrichedItem.Add('ComplianceWorkloadEnabled', $item.configurationManagerClientEnabledFeatures.compliancePolicy)
        if ($null -eq $enrichedItem.ComplianceWorkloadEnabled) 
        {
            $enrichedItem.ComplianceWorkloadEnabled ='N/A'
        }
        }   
        catch 
        {
            $enrichedItem.ComplianceWorkloadEnabled = 'N/A'
        }
        $enrichedItem.Add('OtherAxtiveDevices', $otherActiveDevices)
        
        #Return enriched object as hashtable
        return $enrichedItem
        }


############################################
# Script Execution
############################################

# Install required MgGraph module(s) if it isn't installed

$module = Import-Module Microsoft.Graph.Authentication -PassThru -ErrorAction Ignore
if (-not $module) {
Write-Warning "Required module Microsoft.Graph.Authentication is missing"
Write-Host "Installing module Microsoft.Graph.Authentication"
try {
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -AllowClobber -Force
}
catch {
Write-Host "Failed to install required module" -ForegroundColor Red
Exit 1
}
}

# Authenticate to Microsoft Graph, remove any existing sessions

$null = Disconnect-Graph -ErrorAction SilentlyContinue
Connect

# Get all Intune devices from Intune graph
$IntuneReport = Get-IntuneReport

# Loop through each user Arom CSV and get their AAD details (as hashtables), storing these in an array of hashtables
$enrichedData = @()
Write-Host ""
Write-Host "Enriching Intune Report with Graph / Entra info..." -NoNewLine

$count = 0
foreach ($item in $IntuneReport) {
$enrichedData += Get-EnrichedData -item $item 
$count ++

if ($count -ge 50) {
Write-Host "..." -NoNewline
$count = 0
}
}
Write Host "Completed" -ForegroundColor Green
# Write the enriched report to a CSV
Write-Host ""
Write-Host "Exporting enriched report"
Write Host ""
Export-EnrichedReport -data $enrichedData
exit 0
