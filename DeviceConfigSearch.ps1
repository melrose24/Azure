# Connect to Microsoft Graph
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All"

# Function to get all pages of results
function Get-MgGraphAllPages {
    param (
        [string]$Uri
    )
    
    $allResults = @()
    $response = Invoke-MgGraphRequest -Method GET -Uri $Uri
    
    if ($response.value) {
        $allResults += $response.value
    }
    
    # Handle pagination
    while ($response.'@odata.nextLink') {
        $response = Invoke-MgGraphRequest -Method GET -Uri $response.'@odata.nextLink'
        if ($response.value) {
            $allResults += $response.value
        }
    }
    
    return $allResults
}

# Initialize array to store all policies
$allPolicies = @()

# 1. Get Device Configurations
Write-Host "Fetching Device Configurations..." -ForegroundColor Cyan
try {
    $deviceConfigs = Get-MgGraphAllPages -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations"
    
    $win10Configs = $deviceConfigs | Where-Object { 
        $_.'@odata.type' -match 'windows10' -or 
        $_.'@odata.type' -match 'windows81' -or
        $_.'@odata.type' -match 'windows'
    }
    
    if ($win10Configs) {
        $allPolicies += $win10Configs
        Write-Host "Found $($win10Configs.Count) Device Configurations" -ForegroundColor Green
    } else {
        Write-Host "Found 0 Device Configurations" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Error fetching Device Configurations: $($_.Exception.Message)" -ForegroundColor Red
}

# 2. Get Configuration Policies (Settings Catalog)
Write-Host "Fetching Configuration Policies (Settings Catalog)..." -ForegroundColor Cyan
try {
    $configPolicies = Get-MgGraphAllPages -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies"
    
    $win10ConfigPolicies = $configPolicies | Where-Object { 
        $_.platforms -match 'windows10' 
    }
    
    if ($win10ConfigPolicies) {
        $allPolicies += $win10ConfigPolicies
        Write-Host "Found $($win10ConfigPolicies.Count) Configuration Policies" -ForegroundColor Green
    } else {
        Write-Host "Found 0 Configuration Policies" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Error fetching Configuration Policies: $($_.Exception.Message)" -ForegroundColor Red
}

# 3. Get Group Policy Configurations (Administrative Templates)
Write-Host "Fetching Group Policy Configurations..." -ForegroundColor Cyan
try {
    $groupPolicyConfigs = Get-MgGraphAllPages -Uri "https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations"
    
    if ($groupPolicyConfigs) {
        $allPolicies += $groupPolicyConfigs
        Write-Host "Found $($groupPolicyConfigs.Count) Group Policy Configurations" -ForegroundColor Green
    } else {
        Write-Host "Found 0 Group Policy Configurations" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Error fetching Group Policy Configurations: $($_.Exception.Message)" -ForegroundColor Red
}

# 4. Get Intent Policies (Endpoint Security)
Write-Host "Fetching Intent Policies..." -ForegroundColor Cyan
try {
    $intents = Get-MgGraphAllPages -Uri "https://graph.microsoft.com/beta/deviceManagement/intents"
    
    # Filter for Windows policies (exclude mobile-only templates)
    $win10Intents = $intents | Where-Object { 
        $_.templateId -notmatch 'android|ios|macos' 
    }
    
    if ($win10Intents) {
        $allPolicies += $win10Intents
        Write-Host "Found $($win10Intents.Count) Intent Policies" -ForegroundColor Green
    } else {
        Write-Host "Found 0 Intent Policies" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Error fetching Intent Policies: $($_.Exception.Message)" -ForegroundColor Red
}

# 5. Get Device Compliance Policies (Windows 10+)
Write-Host "Fetching Device Compliance Policies..." -ForegroundColor Cyan
try {
    $compliancePolicies = Get-MgGraphAllPages -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies"
    
    $win10Compliance = $compliancePolicies | Where-Object { 
        $_.'@odata.type' -match 'windows10' -or
        $_.'@odata.type' -match 'windows'
    }
    
    if ($win10Compliance) {
        $allPolicies += $win10Compliance
        Write-Host "Found $($win10Compliance.Count) Compliance Policies" -ForegroundColor Green
    } else {
        Write-Host "Found 0 Compliance Policies" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Error fetching Compliance Policies: $($_.Exception.Message)" -ForegroundColor Red
}

# Display results
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Total Windows 10+ Policies Found: $($allPolicies.Count)" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan

if ($allPolicies.Count -gt 0) {
    # Group by type for better organization
    $groupedPolicies = $allPolicies | Group-Object -Property '@odata.type'
    
    foreach ($group in $groupedPolicies) {
        Write-Host "`nPolicy Type: $($group.Name)" -ForegroundColor Magenta
        Write-Host "Count: $($group.Count)" -ForegroundColor Magenta
        Write-Host "-----------------------------------" -ForegroundColor Gray
        
        foreach ($policy in $group.Group) {
            Write-Host "  Display Name: " -NoNewline; Write-Host "$($policy.displayName)" -ForegroundColor Yellow
            Write-Host "  ID: $($policy.id)"
            
            if ($policy.lastModifiedDateTime) {
                Write-Host "  Last Modified: $($policy.lastModifiedDateTime)"
            }
            if ($policy.platforms) {
                Write-Host "  Platforms: $($policy.platforms -join ', ')"
            }
            Write-Host ""
        }
    }

    # Export to CSV
    $exportData = @()
    foreach ($policy in $allPolicies) {
        $exportData += [PSCustomObject]@{
            DisplayName = $policy.displayName
            ID = $policy.id
            Type = $policy.'@odata.type'
            LastModified = $policy.lastModifiedDateTime
            Platforms = if ($policy.platforms) { $policy.platforms -join ', ' } else { "N/A" }
            Description = $policy.description
        }
    }
    
    $exportPath = "Windows10_DeviceConfigs_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $exportData | Export-Csv -Path $exportPath -NoTypeInformation
    Write-Host "`nExported to $exportPath" -ForegroundColor Green
    
    # Summary by type
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Summary by Policy Type:" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    $groupedPolicies | ForEach-Object {
        Write-Host "$($_.Name): $($_.Count)" -ForegroundColor White
    }
}
else {
    Write-Host "No policies found." -ForegroundColor Yellow
}