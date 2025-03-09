# Intune Drive Mapping Script Documentation

## Description
This script maps network drives based on a predefined configuration (usually provided by an Intune drive mapping generator). When run as the SYSTEM account (e.g., via Intune), it will set up a scheduled task to run this script at user logon. When run as a regular user (e.g., via the scheduled task), it will map the drives as specified.

## Usage

1. **Transcript Logging**: The script starts by setting up transcript logging to capture all output and errors during execution.
2. **Drive Mapping Configuration**: The script reads a JSON configuration that specifies the network drives to be mapped.
3. **User Context Handling**: The script substitutes the current username into any path or label that contains `%USERNAME%`.
4. **Active Directory Group Membership**: The script includes a helper function to retrieve AD group memberships for a given user.
5. **Drive Mapping Execution**: The script maps the network drives as specified in the configuration, handling any existing mappings and potential conflicts.
6. **Scheduled Task Setup**: When run as SYSTEM, the script sets up a scheduled task to run the drive mapping script at user logon and on network state changes.

## Configuration

- **Drive Mapping JSON**: The JSON configuration should include the following fields for each drive mapping:
  - `Path`: The network path to the shared folder.
  - `DriveLetter`: The drive letter to assign.
  - `Label`: The label for the drive (optional).
  - `Id`: A unique identifier for the mapping.
  - `GroupFilter`: A comma-separated list of AD groups that should have access to this mapping (optional).

## Example Drive Mapping JSON
```json
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
