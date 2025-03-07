<#
.DESCRIPTION
    This script maps network drives based on a predefined configuration (usually provided by an Intune drive mapping generator).
    When run as the SYSTEM account (e.g., via Intune), it will set up a scheduled task to run this script at user logon.
    When run as a regular user (e.g., via the scheduled task), it will map the drives as specified.

.NOTES
    Original Author: Nicola Suter, nicolonsky tech (https://tech.nicolonsky.ch)
    Optimized by: Zachary Lowes
#>

[CmdletBinding()]
Param()

# ============================================================================== 
# Start transcript for logging 
# ==============================================================================
$transcriptPath    = Join-Path -Path $env:Temp -ChildPath "DriveMapping.log"
$transcriptStarted = $false
try {
    Start-Transcript -Path $transcriptPath -ErrorAction Stop
    $transcriptStarted = $true
} catch {
    Write-Warning "Could not start transcript logging: $($_.Exception.Message)"
}

# ============================================================================== 
# Input drive mapping configuration (JSON format)
# ==============================================================================
# Example format for entries in $driveMappingJson:
# [
#   {
#     "Path": "\\\\server-name\\share-name",
#     "DriveLetter": "X",
#     "Label": "Label for the drive",
#     "Id": 1,
#     "GroupFilter": "Group-Name"
#   },
#   {
#     "Path": "\\\\another-server\\another-share",
#     "DriveLetter": "Y",
#     "Label": "Another Label",
#     "Id": 2,
#     "GroupFilter": "Another-Group"
#   }
# ]
$driveMappingJson = @'
[
  {
    "Path": "\\\\server-name\\share-name",
    "DriveLetter": "X",
    "Label": "Label for the drive",
    "Id": 1,
    "GroupFilter": "Group-Name"
  },
  {
    "Path": "\\\\another-server\\another-share",
    "DriveLetter": "Y",
    "Label": "Another Label",
    "Id": 2,
    "GroupFilter": "Another-Group"
  }
]
'@

# Convert JSON to PowerShell objects
try {
    $driveMappings = $driveMappingJson | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Error "Failed to parse drive mapping configuration: $($_.Exception.Message)"
    $driveMappings = @()  # proceed with an empty configuration on JSON parse error
}

# Create an array of drive mapping objects, splitting any comma-separated group filters into arrays
$driveMappings = foreach ($map in $driveMappings) {
    [PSCustomObject]@{
        Path        = $map.Path
        DriveLetter = $map.DriveLetter
        Label       = $map.Label
        Id          = $map.Id
        GroupFilter = if ([string]::IsNullOrEmpty($map.GroupFilter)) {
                          $null
                      } else {
                          $map.GroupFilter -split ","
                      }
    }
}

# Get the current username and substitute it into any path/label that contains %USERNAME%
$userName = $env:USERNAME
foreach ($mapping in $driveMappings) {
    if ($mapping.Path -match "%USERNAME%") {
        $mapping.Path = $mapping.Path -replace "%USERNAME%", $userName
    }
    if ($mapping.Label -match "%USERNAME%") {
        $mapping.Label = $mapping.Label -replace "%USERNAME%", $userName
    }
}

# Override this with your Active Directory domain name (e.g., 'yourdomain.com') if $env:USERDNSDOMAIN is not populated
$domainName = ""

# Enable removal of stale mapped drives (those not in config) by setting this to $true
$removeStaleDrives = $false

# ============================================================================== 
# Helper function: Retrieve AD group memberships for a given user 
# ==============================================================================
function Get-ADGroupMembership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$UserPrincipalName
    )
    process {
        try {
            if ([string]::IsNullOrEmpty($env:USERDNSDOMAIN) -and [string]::IsNullOrEmpty($domainName)) {
                Write-Error "Active Directory domain is not available. Cannot determine group memberships."
                Write-Warning "Set the `$domainName` variable to your AD domain name to enable group-based filtering."
                return @()  # return empty list if domain not available
            }
            # Determine the LDAP search root (use override if provided, otherwise environment domain)
            $searchDomain = if ([string]::IsNullOrEmpty($domainName)) { $env:USERDNSDOMAIN } else { $domainName }
            $searcher = New-Object System.DirectoryServices.DirectorySearcher
            $searcher.Filter     = "(&(userprincipalname=$UserPrincipalName))"
            $searcher.SearchRoot = "LDAP://$searchDomain"
            $userObject = $searcher.FindOne()
            if (-not $userObject) {
                Write-Warning "User '$UserPrincipalName' not found in directory '$searchDomain'."
                return @()
            }
            $distinguishedName = $userObject.Properties.distinguishedname
            # Search for all group memberships recursively (using LDAP_MATCHING_RULE_IN_CHAIN)
            $searcher.Filter = "(member:1.2.840.113556.1.4.1941:=$distinguishedName)"
            [void]$searcher.PropertiesToLoad.Add("name")
            $groupList = New-Object System.Collections.Generic.List[string]
            $results   = $searcher.FindAll()
            foreach ($result in $results) {
                $groupList.Add($result.Properties.name)
            }
            return $groupList
        } catch {
            Write-Warning "Error retrieving group memberships: $($_.Exception.Message)"
            return @()  # return empty list on error to avoid stopping script
        }
    }
}

# Helper function: Detect if running as SYSTEM (returns $true if running under Local System account)
function Test-RunningAsSystem {
    [CmdletBinding()]
    param()
    process {
        return ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq "S-1-5-18")
    }
}

# Helper function: Filter drive mappings by user group membership
function Test-GroupMembership {
    [CmdletBinding()]
    param(
        [Array]$Mappings,
        [Array]$GroupMemberships
    )
    process {
        try {
            $filteredMappings = foreach ($map in $Mappings) {
                if ($map.GroupFilter -ne $null -and $map.GroupFilter.Count -gt 0) {
                    # If any group in GroupFilter matches the user's groups, include this mapping
                    foreach ($filter in $map.GroupFilter) {
                        if ($GroupMemberships -contains $filter) {
                            $map
                            break  # include mapping once if any filter matches, then break out of inner loop
                        }
                    }
                } else {
                    # No group filter specified for this mapping; include it
                    $map
                }
            }
            return $filteredMappings
        } catch {
            Write-Error "Unknown error during group filtering: $($_.Exception.Message)"
            return $Mappings  # in case of error, return all mappings unfiltered
        }
    }
}

# ============================================================================== 
# Mapping network drives (executes only in user context, not SYSTEM) 
# ==============================================================================
Write-Output "Running as SYSTEM: $(Test-RunningAsSystem)"

if (-not (Test-RunningAsSystem)) {
    # Determine if group-based filtering is needed and retrieve group memberships
    $groupMemberships     = @()
    $membershipCheckFailed = $false
    $needsGroupFiltering   = $driveMappings | Where-Object { $_.GroupFilter -ne $null -and $_.GroupFilter.Count -gt 0 }
    if ($needsGroupFiltering.Count -gt 0) {
        try {
            # Get current user's UPN and retrieve their group memberships
            $groupMemberships = Get-ADGroupMembership -UserPrincipalName (whoami -upn)
        } catch {
            Write-Warning "Group membership lookup failed: $($_.Exception.Message)"
            $membershipCheckFailed = $true
        }
    }

    # Filter the drive mappings according to the user's group memberships (if any filtering is required)
    $driveMappings = Test-GroupMembership -Mappings $driveMappings -GroupMemberships $groupMemberships

    # Get currently mapped FileSystem drives (excluding OS drives like C: and D:)
    $psDrives = Get-PSDrive -PSProvider FileSystem | Where-Object {
        $_.Root -notin @("$($env:SystemDrive)\", "D:\")
    } | Select-Object @{Name = 'DriveLetter'; Expression = { $_.Name }},
                         @{Name = 'Path';        Expression = { $_.DisplayRoot }}

    # Iterate through each configured drive mapping and ensure it is mapped
    foreach ($mapping in $driveMappings) {
        try {
            # Expand any $env: variables in the path (if present)
            if ($mapping.Path -match '\$env:') {
                $mapping.Path = $ExecutionContext.InvokeCommand.ExpandString($mapping.Path)
            }
            # Use an empty string if label is null (avoids errors when mapping)
            if ($null -eq $mapping.Label) {
                $mapping.Label = ""
            }
            # Check if a drive with this letter or path is already mapped
            $existingMapping = $psDrives | Where-Object { $_.Path -eq $mapping.Path -or $_.DriveLetter -eq $mapping.DriveLetter }
            $shouldMap = $true
            if ($existingMapping) {
                if ($existingMapping.Path -eq $mapping.Path -and $existingMapping.DriveLetter -eq $mapping.DriveLetter) {
                    Write-Output "Drive '$($mapping.DriveLetter):' already mapped to '$($mapping.Path)', skipping."
                    $shouldMap = $false
                } else {
                    # A drive is mapped with this letter or path but does not match the desired configuration – remove it
                    Write-Output "Removing conflicting drive mapping ($($mapping.DriveLetter): or path $($mapping.Path))"
                    Get-PSDrive | Where-Object { $_.DisplayRoot -eq $mapping.Path -or $_.Name -eq $mapping.DriveLetter } | 
                        Remove-PSDrive -ErrorAction SilentlyContinue
                }
            }
            if ($shouldMap) {
                Write-Output "Mapping drive $($mapping.DriveLetter): to path '$($mapping.Path)'"
                New-PSDrive -Name $mapping.DriveLetter -PSProvider FileSystem -Root $mapping.Path `
                           -Description $($mapping.Label) -Persist -Scope Global -ErrorAction Stop | Out-Null
                # Set the drive's label (visible in File Explorer) if a label is specified
                $shellApp = New-Object -ComObject Shell.Application
                $shellApp.NameSpace("$($mapping.DriveLetter):").Self.Name = $mapping.Label
            }
        } catch {
            # Log the error but continue with the next mapping
            if (-not (Test-Path -LiteralPath $mapping.Path)) {
                Write-Error "Unable to access network path '$($mapping.Path)'. Verify that the path is correct and accessible."
            } else {
                Write-Error "Error mapping drive $($mapping.DriveLetter): $($_.Exception.Message)"
            }
        }
    }

    # Clean up drives that are not in the current configuration, if enabled and safe to do so
    if ($removeStaleDrives -and -not $membershipCheckFailed) {
        if ($psDrives) {
            # Find drives that exist in $psDrives but were not assigned in $driveMappings
            $staleDrives = Compare-Object -ReferenceObject $driveMappings -DifferenceObject $psDrives -Property DriveLetter -PassThru |
                           Where-Object { $_.SideIndicator -eq '=>' }
            foreach ($unassigned in $staleDrives) {
                # Only remove if the unassigned drive appears to be a network drive (UNC path)
                if ($unassigned.Path -like '\\*') {
                    Write-Warning "Removing stale drive mapping '$($unassigned.DriveLetter):' (not in current configuration)."
                    Remove-SmbMapping -LocalPath "$($unassigned.DriveLetter):" -Force -UpdateProfile -ErrorAction SilentlyContinue
                } else {
                    Write-Output "Drive '$($unassigned.DriveLetter):' is not a network mapping; skipping removal."
                }
            }
        }
    } elseif ($removeStaleDrives -and $membershipCheckFailed) {
        Write-Warning "Stale drive cleanup skipped due to group membership lookup failure."
    }

    # Ensure all mapped drives are marked as persistent (so they reconnect at logon)
    Get-ChildItem HKCU:\Network -ErrorAction SilentlyContinue | ForEach-Object {
        New-ItemProperty -Path $_.PSPath -Name "ConnectionType" -Value 1 -Force -ErrorAction SilentlyContinue
    }
}

# Stop the transcript for the above operations (if it was successfully started)
if ($transcriptStarted) {
    try {
        Stop-Transcript -ErrorAction Stop
    } catch {
        Write-Warning "Failed to stop transcript: $($_.Exception.Message)"
    }
}

#!SCHTASKCOMESHERE!#

# ============================================================================== 
# Scheduled Task Setup (executes only when running as SYSTEM) 
# ==============================================================================
if (Test-RunningAsSystem) {
    $schedTransStarted = $false
    # Start a separate transcript for scheduled task setup logging
    try {
        Start-Transcript -Path (Join-Path -Path $env:Temp -ChildPath "IntuneDriveMappingScheduledTask.log") -ErrorAction Stop
        $schedTransStarted = $true
    } catch {
        Write-Warning "Could not start transcript for scheduled task configuration: $($_.Exception.Message)"
    }
    try {
        Write-Output "Running as SYSTEM - registering scheduled task for user drive mapping..."

        # Save the current script content (up to the placeholder) to a file that will run at user logon
        $scriptLines = Get-Content -Path $PSCommandPath
        $stopIndex   = [Array]::IndexOf($scriptLines, "#!SCHTASKCOMESHERE!#")
        $scriptToSave = if ($stopIndex -gt -1) {
            $scriptLines[0..($stopIndex - 1)]
        } else {
            Write-Warning "Placeholder not found. Saving full script for scheduled task."
            $scriptLines
        }
        $scriptDir = Join-Path -Path $env:ProgramData -ChildPath "intune-drive-mapping-generator"
        if (-not (Test-Path $scriptDir)) {
            New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
        }
        $scriptFilePath = Join-Path -Path $scriptDir -ChildPath "DriveMapping.ps1"
        $scriptToSave | Out-File -FilePath $scriptFilePath -Encoding UTF8 -Force

        # Create a VBScript to launch the PowerShell script without a visible window
        $vbsContent = @'
Dim shell, fso, file
Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")
strPath  = WScript.Arguments.Item(0)
If fso.FileExists(strPath) Then
    Set file = fso.GetFile(strPath)
    strCMD = "powershell -NoLogo -ExecutionPolicy Bypass -Command " & Chr(34) & "&{" & file.ShortPath & "}" & Chr(34)
    shell.Run strCMD, 0
End If
'@
        $vbsFilePath = Join-Path -Path $scriptDir -ChildPath "IntuneDriveMapping-VBSHelper.vbs"
        $vbsContent | Out-File -FilePath $vbsFilePath -Encoding ASCII -Force

        # Define triggers: at user logon, and on network state change (connect/disconnect events)
        $triggerLogon = New-ScheduledTaskTrigger -AtLogOn
        $triggerNet1  = [CimClass]("root/Microsoft/Windows/TaskScheduler:MSFT_TaskEventTrigger") | New-CimInstance -ClientOnly
        $triggerNet1.Enabled     = $true
        $triggerNet1.Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational">' +
                                    '<Select Path="Microsoft-Windows-NetworkProfile/Operational">' +
                                    '*[System[Provider[@Name=''Microsoft-Windows-NetworkProfile''] and EventID=10002]]' +
                                    '</Select></Query></QueryList>'
        $triggerNet2  = [CimClass]("root/Microsoft/Windows/TaskScheduler:MSFT_TaskEventTrigger") | New-CimInstance -ClientOnly
        $triggerNet2.Enabled     = $true
        $triggerNet2.Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational">' +
                                    '<Select Path="Microsoft-Windows-NetworkProfile/Operational">' +
                                    '*[System[Provider[@Name=''Microsoft-Windows-NetworkProfile''] and EventID=4004]]' +
                                    '</Select></Query></QueryList>'

        # Set the task principal to run in the context of the built-in Users group (all users), with limited privileges
        $taskPrincipal = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-545" -RunLevel Limited

        # Define the action to execute the PowerShell script via the VBScript (to hide the PowerShell window)
        $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot "System32\\wscript.exe") `
                                         -Argument "\"$vbsFilePath\" \"$scriptFilePath\""

        # Register the scheduled task (will overwrite an existing task with the same name)
        $taskName = "IntuneDriveMapping"
        $taskDesc = "Map network drives on user logon (Intune Drive Mapping script)"
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Trigger $triggerLogon, $triggerNet1, $triggerNet2 `
                               -Action $action -Principal $taskPrincipal -Settings $settings -Description $taskDesc -Force

        # Start the task now (to perform drive mapping immediately for any current user session)
        Start-ScheduledTask -TaskName $taskName
        Write-Output "Scheduled task '$taskName' has been registered and started successfully."
    } catch {
        Write-Error "Failed to configure scheduled task: $($_.Exception.Message)"
    } finally {
        if ($schedTransStarted) {
            try {
                Stop-Transcript -ErrorAction Stop
            } catch {
                Write-Warning "Failed to stop scheduled task setup transcript: $($_.Exception.Message)"
            }
        }
    }
}
