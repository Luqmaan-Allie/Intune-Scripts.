# Import required Microsoft Graph modules
Import-Module Microsoft.Graph.Intune
Import-Module Microsoft.Graph.Groups

# Connect to Microsoft Graph with the required permissions
# The scopes specified here should allow reading and writing devices, reading groups, users, and directory objects.
Connect-MgGraph -Scopes "Device.ReadWrite.All","Group.Read.All","User.Read.All","Directory.Read.All"

# Hash table mapping Entra ID user groups to Intune device categories.
# Keys: Entra ID Group displayName
# Values: Corresponding Intune Device Category displayName
$GroupCategoryMap = @{
    "AZR-S-All Chicago Users"       = "CHI Device"
    "AZR-S-All Charlotte Users"     = "CLT Device"
    "AZR-S-All New York Users"      = "NYC Device"
    "AZR-S-All Los Angeles Users"   = "LAX Device"
    "AZR-S-All London Users"        = "LON Device"
    "AZR-S-All Orange County Users" = "OCC Device"
    "AZR-S-All Dallas Users"        = "DAL Device"
    "AZR-S-All Washington Users"    = "WAS Device"
    "AZR-S-All Shanghai Users"      = "SHA Device"
}

# Retrieves the UPNs of all users in a given group (by group displayName).
# Uses beta endpoint directly via Invoke-MgGraphRequest.
function Get-GroupMemberUPNs {
    param (
        [Parameter(Mandatory)]
        [string]$GroupName
    )

    try {
        # Retrieve group using the beta endpoint by filtering on displayName
        $groupResponse = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/groups?`$filter=displayName eq '$GroupName'" -Method GET -ErrorAction Stop
        $groupData = $groupResponse.value

        if (-not $groupData -or $groupData.Count -eq 0) {
            Write-Warning "Group '$GroupName' not found."
            return $null
        }

        # Assume uniqueness of displayName, take the first match
        $group = $groupData[0]
        Write-Host "Found Group: $($group.displayName) (ID: $($group.id))"

        # Get members of the group (also from beta endpoint)
        $membersUri = "https://graph.microsoft.com/beta/groups/$($group.id)/members?`$count=true"
        $allMembers = @()
        $nextLink = $membersUri

        # Handle pagination for group members if needed
        while ($nextLink) {
            $memberResponse = Invoke-MgGraphRequest -Uri $nextLink -Method GET -ErrorAction Stop -Headers @{ "ConsistencyLevel" = "eventual" }
            $allMembers += $memberResponse.value
            $nextLink = $memberResponse.'@odata.nextLink'
        }

        $members = @()

        # Extract user UPNs from member objects that are users
        foreach ($member in $allMembers) {
            $memberType = $member.'@odata.type'
            if ($memberType -eq '#microsoft.graph.user') {
                # Get user details (for UPN) from the beta endpoint
                $userResponse = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/users/$($member.id)" -Method GET -ErrorAction Stop
                if ($null -ne $userResponse -and $userResponse.userPrincipalName) {
                    $members += $userResponse.userPrincipalName
                }
            }
        }

        if ($members.Count -eq 0) {
            Write-Warning "No users found in group '$GroupName'."
            return $null
        }

        Write-Host "Total Members Found: $($members.Count)"
        return $members
    }
    catch {
        Write-Error "Error retrieving members for group '$GroupName': $_"
        return $null
    }
}

# Assigns a specified device category to all devices associated with a given user's UPN.
# This function:
# - Looks up the device category by name (must exist in Intune).
# - Retrieves the user's devices by userPrincipalName.
# - Assigns the category by adding a reference to the deviceCategory object using a PUT request.
function Assign-DeviceCategory {
    param (
        [Parameter(Mandatory)]
        [string]$UserPrincipalName,

        [Parameter(Mandatory)]
        [string]$CategoryName
    )

    try {
        # Get the device category object from beta endpoint based on DisplayName
        $categoryResponse = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceCategories?`$filter=displayName eq '$CategoryName'" -Method GET -ErrorAction Stop
        $categoryData = $categoryResponse.value

        if (-not $categoryData -or $categoryData.Count -eq 0) {
            Write-Warning "Device category '$CategoryName' not found in Intune. Please ensure it exists."
            return
        }

        $categoryId = $categoryData[0].id

        # Get devices for this user
        $deviceResponse = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=userPrincipalName eq '$UserPrincipalName'" -Method GET -ErrorAction Stop
        $devices = $deviceResponse.value

        if (-not $devices -or $devices.Count -eq 0) {
            Write-Warning "No devices found for user '$UserPrincipalName'. This could mean no enrolled devices or incorrect UPN."
            return
        }

        # Assign the category to each device
        foreach ($device in $devices) {
            Write-Host "Assigning category '$CategoryName' to device '$($device.deviceName)'"

            # Build the request body referencing the category by ID
            $body = @{
                "@odata.id" = "https://graph.microsoft.com/beta/deviceManagement/deviceCategories/$categoryId"
            }

            # PUT request to assign the device category reference
            Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($device.id)/deviceCategory/`$ref" -Method PUT -Body $body -ErrorAction Stop
            
            # Verify the update
            $updatedDeviceResponse = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($device.id)" -Method GET -ErrorAction Stop
            $updatedCategory = $updatedDeviceResponse.deviceCategoryDisplayName

            if ($updatedCategory -eq $CategoryName) {
                Write-Host "Category successfully updated to '$CategoryName' on device '$($device.deviceName)'."
            }
            else {
                Write-Warning "Category update for device '$($device.deviceName)' did not reflect as expected."
            }
        }
    }
    catch {
        Write-Error "Error assigning category '$CategoryName' to devices for user '$UserPrincipalName': $_"
    }
}

# Main logic to iterate over each group in the hash table and assign categories
foreach ($group in $GroupCategoryMap.Keys) {
    $category = $GroupCategoryMap[$group]
    Write-Host "`nProcessing group '$group' for category '$category'..."

    $groupMemberUPNs = Get-GroupMemberUPNs -GroupName $group

    if ($groupMemberUPNs) {
        foreach ($upn in $groupMemberUPNs) {
            Write-Host "Processing user '$upn'"
            Assign-DeviceCategory -UserPrincipalName $upn -CategoryName $category
        }
    }
    else {
        Write-Warning "No members found or error occurred for group '$group'."
    }
}

Write-Host "`nScript completed."