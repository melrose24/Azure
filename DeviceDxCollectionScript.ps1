<#
.SYNOPSIS
Intune Device Diagnostics Collection Script

.DESCRIPTION
Collects diagnostic information for troubleshooting Intune-managed devices:
- dsregcmd /status output
- Intune Management Extension (IME) logs
- Network connectivity tests


Saves results as a ZIP file on the user's desktop with timestamp.
Designed to run via Intune as SYSTEM with admin privileges.


.NOTES
Author: IT Support
Version: 1.0
Requires: PowerShell 5.1 or higher, Admin rights (SYSTEM context)
#>

#Requires -Version 5.1

# Function to get the currently logged-in user

function Get-LoggedInUser {
try {
$quser = query user 2>&1
if ($LASTEXITCODE -eq 0) {
$users = $quser -replace '\s{2,}', ',' | ConvertFrom-Csv
$activeUser = $users | Where-Object { $_.STATE -eq 'Active' } | Select-Object -First 1
if ($activeUser) {
return $activeUser.USERNAME
}
}


# Fallback method using WMI
$user = Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty UserName
if ($user) {
return $user.Split('\')[-1]
}

return $null
}
catch {
Write-Output "Error detecting logged-in user: $_"
return $null
}


}

# Function to get user's desktop path

function Get-UserDesktopPath {
param([string]$Username)


try {
# Primary method: C:\Users\Username\Desktop
$desktopPath = "C:\Users\$Username\Desktop"
if (Test-Path $desktopPath) {
return $desktopPath
}

# Fallback: Query registry for desktop path
$userSID = (New-Object System.Security.Principal.NTAccount($Username)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$regPath = "Registry::HKEY_USERS\$userSID\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
if (Test-Path $regPath) {
$desktop = (Get-ItemProperty -Path $regPath -Name Desktop).Desktop
$desktop = $desktop -replace '%USERPROFILE%', "C:\Users\$Username"
return $desktop
}

return $desktopPath
}
catch {
Write-Output "Error getting desktop path: $_"
return "C:\Users\$Username\Desktop"
}


}

# Main script execution

try {
Write-Output “Intune Device Diagnostics Collection Started”
Write-Output “Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')”


# Detect logged-in user
$loggedInUser = Get-LoggedInUser
if (-not $loggedInUser) {
Write-Output "ERROR: No active user detected. Script must run when a user is logged in."
exit 1
}
Write-Output "Detected logged-in user: $loggedInUser"

# Get user's desktop path
$desktopPath = Get-UserDesktopPath -Username $loggedInUser
Write-Output "Desktop path: $desktopPath"

# Create timestamp for folder and file names
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$tempFolderName = "IntuneDeviceDiag_$timestamp"
$tempFolderPath = Join-Path $env:TEMP $tempFolderName

# Create temporary folder for diagnostics
New-Item -Path $tempFolderPath -ItemType Directory -Force | Out-Null
Write-Output "Created temp folder: $tempFolderPath"

# --- Collect Device Information ---
Write-Output "`n--- Collecting Device Information ---"
$deviceInfo = @"


# Device Diagnostics Collection

Collection Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Computer Name: $env:COMPUTERNAME
Logged-in User: $loggedInUser
OS Version: $([System.Environment]::OSVersion.VersionString)
PowerShell Version: $($PSVersionTable.PSVersion.ToString())

“@
$deviceInfo | Out-File -FilePath (Join-Path $tempFolderPath “DeviceInfo.txt”) -Encoding UTF8


# --- Collect dsregcmd /status ---
Write-Output "`n--- Collecting dsregcmd /status ---"
try {
$dsregOutput = & dsregcmd /status 2>&1 | Out-String
$dsregOutput | Out-File -FilePath (Join-Path $tempFolderPath "dsregcmd_status.txt") -Encoding UTF8
Write-Output " dsregcmd /status collected"
}
catch {
$errorMsg = "ERROR collecting dsregcmd: $_"
Write-Output $errorMsg
$errorMsg | Out-File -FilePath (Join-Path $tempFolderPath "dsregcmd_status_ERROR.txt") -Encoding UTF8
}

# --- Collect Intune Management Extension Logs ---
Write-Output "`n--- Collecting IME Logs ---"
$imeLogPaths = @(
"C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log",
"C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AgentExecutor.log",
"C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\ClientHealth.log"
)

$imeLogsFolder = Join-Path $tempFolderPath "IME_Logs"
New-Item -Path $imeLogsFolder -ItemType Directory -Force | Out-Null

foreach ($logPath in $imeLogPaths) {
if (Test-Path $logPath) {
try {
$logFileName = Split-Path $logPath -Leaf
Copy-Item -Path $logPath -Destination (Join-Path $imeLogsFolder $logFileName) -Force
Write-Output " Collected: $logFileName"
}
catch {
Write-Output " Failed to copy: $logPath - $_"
}
}
else {
Write-Output " Log not found: $logPath"
}
}

# Collect last 100 lines from main IME log as excerpt
try {
$mainImeLog = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
if (Test-Path $mainImeLog) {
$lastLines = Get-Content $mainImeLog -Tail 100 | Out-String
"Last 100 lines of IntuneManagementExtension.log`n" + "="*50 + "`n" + $lastLines |
Out-File -FilePath (Join-Path $tempFolderPath "IME_Log_Excerpt.txt") -Encoding UTF8
Write-Output " Created IME log excerpt (last 100 lines)"
}
}
catch {
Write-Output " Failed to create IME excerpt: $_"
}

# --- Network Connectivity Tests ---
Write-Output "`n--- Running Network Tests ---"
$networkResults = @"


# Network Connectivity Tests

Test Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

“@


# Test 1: DNS Resolution
Write-Output "Testing DNS resolution..."
$dnsTests = @(
"login.microsoftonline.com",
"graph.microsoft.com",
"enrollment.manage.microsoft.com"
)

foreach ($hostname in $dnsTests) {
try {
$dnsResult = Resolve-DnsName -Name $hostname -ErrorAction Stop
$networkResults += " DNS OK: $hostname -> $($dnsResult[0].IPAddress)`n"
}
catch {
$networkResults += " DNS FAILED: $hostname - $_`n"
}
}

$networkResults += "`n"

# Test 2: Ping Tests - Depends in Customer Allows or Not
# May need to Remove or Comment out Test 2
Write-Output "Testing connectivity (ping)..."
$pingTests = @(
"8.8.8.8",
"login.microsoftonline.com"
)

foreach ($target in $pingTests) {
try {
$pingResult = Test-Connection -ComputerName $target -Count 2 -ErrorAction Stop
$avgTime = ($pingResult | Measure-Object -Property ResponseTime -Average).Average
$networkResults += " PING OK: $target (Avg: $([math]::Round($avgTime, 2))ms)`n"
}
catch {
$networkResults += " PING FAILED: $target - $_`n"
}
}

$networkResults += "`n"

# Test 3: HTTPS Connectivity
Write-Output "Testing HTTPS connectivity..."
$httpsTests = @(
"https://login.microsoftonline.com",
"https://graph.microsoft.com",
"https://portal.manage.microsoft.com"
)

foreach ($url in $httpsTests) {
try {
$response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
$networkResults += " HTTPS OK: $url (Status: $($response.StatusCode))`n"
}
catch {
$networkResults += " HTTPS FAILED: $url - $($_.Exception.Message)`n"
}
}

# Test 4: Get IP Configuration
Write-Output "Collecting IP configuration..."
$networkResults += "`n" + "="*50 + "`n"
$networkResults += "IP Configuration:`n"
$networkResults += "="*50 + "`n"

try {
$ipconfig = ipconfig /all 2>&1 | Out-String
$networkResults += $ipconfig
}
catch {
$networkResults += "ERROR: Failed to get ipconfig - $_`n"
}

# Save network results
$networkResults | Out-File -FilePath (Join-Path $tempFolderPath "NetworkTests.txt") -Encoding UTF8
Write-Output " Network tests completed"

# --- Create ZIP File ---
Write-Output "`n--- Creating ZIP archive ---"
$zipFileName = "IntuneDeviceDiag_${loggedInUser}_$timestamp.zip"
$zipFilePath = Join-Path $desktopPath $zipFileName

# Ensure desktop path exists
if (-not (Test-Path $desktopPath)) {
New-Item -Path $desktopPath -ItemType Directory -Force | Out-Null
}

# Create ZIP using .NET compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($tempFolderPath, $zipFilePath)

Write-Output " ZIP file created: $zipFilePath"

# --- Cleanup ---
Write-Output "`n--- Cleaning up temporary files ---"
Remove-Item -Path $tempFolderPath -Recurse -Force -ErrorAction SilentlyContinue
Write-Output " Temporary files removed"

# --- Final Summary ---
Write-Output "`n=== Diagnostics Collection Complete ==="
Write-Output "ZIP file location: $zipFilePath"
Write-Output "File size: $([math]::Round((Get-Item $zipFilePath).Length / 1KB, 2)) KB"
Write-Output "`nUser can find the diagnostics file on their desktop."
Write-Output "File name: $zipFileName"

exit 0


}
catch {
Write-Output “`n=== ERROR ===”
Write-Output “An unexpected error occurred: $*”
Write-Output $*.ScriptStackTrace
exit 1
}

