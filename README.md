# WSL Disk Mount Scripts

This project provides automated scripts to mount physical Linux disks for Windows Subsystem for Linux (WSL) using VHD files. The scripts are designed to run at system startup or user login to automatically mount your Linux disk for WSL access.

## Overview

The project includes two equivalent implementations:
- **`mount-wsl-disk.py`** - Python implementation
- **`mount-wsl-disk.ps1`** - PowerShell implementation

Both scripts provide identical functionality with the same command-line interface and behavior.

## Purpose

Mount a Windows host physical Linux disk (for WSL) using a VHD file. The scripts are intended to run at user logon or manually, and they handle:
- Shutdown of WSL instances
- Attachment of the VHD file
- Host-side mounting via `wsl --mount`

## Key Requirements

- **Administrator privileges are REQUIRED** to run these scripts
- **WSL must be shut down** to mount disks (scripts run `wsl --shutdown` automatically)
- Windows Subsystem for Linux must be installed and configured

## How It Works

Each script performs the following steps per attempt:

1. **Stop all WSL instances**: `wsl --shutdown`
2. **Ensure VHD is attached**: `Mount-VHD` (if not already attached)
3. **Mount the disk to WSL**: `wsl --mount --vhd <VHD_PATH> --partition <N>`

## Reliability Features

- Each critical step has a timeout of 60 seconds by default
- If any step times out, the entire sequence is retried from scratch, up to 3 attempts
- Non-timeout failures do not trigger retries
- Comprehensive error handling and logging

## Usage

### Python Script

```bash
python mount-wsl-disk.py [options]
```

**Options:**
- `--vhd-path PATH` - Override VHD path (default: `E:\wsl_data.vhdx`)
- `--physical-drive PATH` - Override physical drive (default: `\\.\PhysicalDrive2`)
- `--partition N` - Override partition number (default: `2`)
- `--verbose` - Enable verbose logging (also via `MOUNT_WSL_VERBOSE=1`)
- `--log-dir PATH` - Override log directory (default: `C:\Scripts`)
- `--help` / `-h` - Show help and exit

**Examples:**
```bash
python mount-wsl-disk.py
python mount-wsl-disk.py --verbose
python mount-wsl-disk.py --vhd-path "D:\my-disk.vhdx" --partition 1
python mount-wsl-disk.py --log-dir "C:\Logs" --verbose
```

### PowerShell Script

```powershell
.\mount-wsl-disk.ps1 [options]
```

**Options:**
- `-VhdPath PATH` - Override VHD path (default: `E:\wsl_data.vhdx`)
- `-PhysicalDrive PATH` - Override physical drive (default: `\\.\PhysicalDrive2`)
- `-Partition N` - Override partition number (default: `2`)
- `-LogDir PATH` - Override log directory (default: `C:\Scripts`)
- `-Verbose` - Verbose logging (or set `MOUNT_WSL_VERBOSE=1`)
- `-Help` / `--help` / `-h` - Show help and exit

**Examples:**
```powershell
.\mount-wsl-disk.ps1
.\mount-wsl-disk.ps1 -Verbose
.\mount-wsl-disk.ps1 -VhdPath "D:\my-disk.vhdx" -Partition 1
.\mount-wsl-disk.ps1 -LogDir "C:\Logs" -Verbose
```

## Exit Codes

| Code | Description |
|------|-------------|
| 0 | Success |
| 2 | WSL not found |
| 3 | Mount failed |
| 4 | Disk/partition not found |
| 5 | Admin rights required |
| 6 | Invalid parameters |
| 7 | Operation timed out |
| 8 | Already mounted |
| 10 | Unexpected error |

## Setting Up Windows Task Scheduler

To automatically run the script after each computer start and user login in administrative mode:

### Method 1: Using Task Scheduler GUI

1. **Open Task Scheduler**:
   - Press `Win + R`, type `taskschd.msc`, and press Enter
   - Or search "Task Scheduler" in the Start menu

2. **Create Basic Task**:
   - Click "Create Basic Task..." in the Actions panel
   - Name: `Mount WSL Disk`
   - Description: `Automatically mount WSL disk on startup/login`

3. **Set Trigger**:
   - Choose "When the computer starts"
   - Click "Next"
   - Choose "When I log on" (if you want it to run on user login too)
   - Click "Next"

4. **Set Action**:
   - Choose "Start a program"
   - Click "Next"
   - **Program/script**: `powershell.exe` (for PowerShell) or `python.exe` (for Python)
   - **Add arguments**: `-ExecutionPolicy Bypass -File "C:\Scripts\mount-wsl-disk.ps1"` (PowerShell) or `C:\Scripts\mount-wsl-disk.py` (Python)
   - **Start in**: `C:\Scripts`

5. **Configure Settings**:
   - Check "Run with highest privileges" (for admin mode)
   - Check "Run whether user is logged on or not"
   - Check "Run task as soon as possible after a scheduled start is missed"

6. **Finish**:
   - Review settings and click "Finish"

### Method 2: Using PowerShell (Run as Administrator)

```powershell
# Create the task
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"C:\Scripts\mount-wsl-disk.ps1`""
$trigger1 = New-ScheduledTaskTrigger -AtStartup
$trigger2 = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName "Mount WSL Disk" -Action $action -Trigger @($trigger1, $trigger2) -Settings $settings -Principal $principal -Description "Automatically mount WSL disk on startup and login"
```

### Method 3: Using Command Line (Run as Administrator)

```cmd
schtasks /create /tn "Mount WSL Disk" /tr "powershell.exe -ExecutionPolicy Bypass -File \"C:\Scripts\mount-wsl-disk.ps1\"" /sc onstart /ru SYSTEM /rl highest /f
```

## Configuration

### Default Settings

- **VHD Path**: `E:\wsl_data.vhdx`
- **Physical Drive**: `\\.\PhysicalDrive2`
- **Partition**: `2`
- **Log File**: `mount-wsl-disk.log`
- **Log Directory**: `C:\Scripts`
- **Per-step Timeout**: 60 seconds
- **Retries**: 3 attempts on timeouts only

### Environment Variables

- `MOUNT_WSL_VERBOSE=1` - Enable verbose logging of command outputs

## Troubleshooting

### Common Issues

1. **"Administrator privileges are required"**
   - Run the script as Administrator
   - Ensure Task Scheduler task is configured with "Run with highest privileges"

2. **"WSL not found"**
   - Install Windows Subsystem for Linux
   - Ensure WSL is properly configured

3. **"Mount failed" or "File in use"**
   - Ensure WSL is shut down before running
   - Check if the VHD file is already attached
   - Verify the VHD file path is correct

4. **"Disk/partition not found"**
   - Verify the physical drive path is correct
   - Check that the partition number exists
   - Ensure the VHD file contains the expected disk structure

### Log Files

Check the log file for detailed information:
- **Location**: `C:\Scripts\mount-wsl-disk.log` (default)
- **Content**: Timestamped logs of all operations
- **Verbose Mode**: Use `-Verbose` flag for detailed command outputs

## Files

- `mount-wsl-disk.py` - Python implementation
- `mount-wsl-disk.ps1` - PowerShell implementation
- `mount-wsl-disk.log` - Log file (created automatically)
- `README.md` - This documentation

## Requirements

### Python Script
- Python 3.6 or higher
- Windows 10/11 with WSL support
- Administrator privileges

### PowerShell Script
- PowerShell 5.1 or higher
- Windows 10/11 with WSL support
- Administrator privileges

## License

This project is provided as-is for educational and personal use.
