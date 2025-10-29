#requires -Version 5.1

param(
    [string]$VhdPath = 'E:\\wsl_data.vhdx',
    [string]$PhysicalDrive = '\\.\\PhysicalDrive2',
    [int]$Partition = 2,
    [string]$LogDir = 'C:\\Scripts',
    [switch]$Verbose,
    [switch]$Help
)

# Single source of help text (concise)
$HELP_TEXT = @"
Usage: .\mount-wsl-disk.ps1 [-VhdPath PATH] [-PhysicalDrive PATH] [-Partition N] [-LogDir PATH] [-Verbose] [-Help]

Purpose: Mount a physical Linux disk for WSL using a VHD file.

Requirements:
  - Must be run as Administrator
  - WSL must be shut down to mount (script runs 'wsl --shutdown')

Defaults:
  - VHD Path:        $VhdPath
  - Physical Drive:  $PhysicalDrive
  - Partition:       $Partition
  - Log File:        mount-wsl-disk.log
  - Log Directory:   $LogDir
  - Per-step Timeout: 60s; Retries: 3 on timeouts only

Options:
  -VhdPath PATH         Override VHD path
  -PhysicalDrive PATH   Override physical drive (e.g. \\.\\PhysicalDrive2)
  -Partition N          Override partition number
  -LogDir PATH          Override log directory
  -Verbose              Verbose logging (or set MOUNT_WSL_VERBOSE=1)
  -Help | --help | -h   Show this help and exit

Examples:
  .\mount-wsl-disk.ps1
  .\mount-wsl-disk.ps1 -Verbose
  .\mount-wsl-disk.ps1 -VhdPath "D:\my-disk.vhdx" -Partition 1
  .\mount-wsl-disk.ps1 -LogDir "C:\Logs" -Verbose

Exit codes:
  0   Success
  2   WSL not found
  3   Mount failed
  4   Disk/partition not found
  5   Admin rights required
  6   Invalid parameters
  7   Operation timed out
  8   Already mounted
  10  Unexpected error
"@

# Allow -h/--help aliases
if ($args -contains '-h' -or $args -contains '--help') { $Help = $true }
if ($Help) {
    Write-Output $HELP_TEXT
    exit 0
}

# Exit codes
$EXIT_SUCCESS = 0
$EXIT_WSL_MISSING = 2
$EXIT_MOUNT_GENERIC_FAIL = 3
$EXIT_TARGET_NOT_FOUND = 4
$EXIT_ADMIN_REQUIRED = 5
$EXIT_INVALID_PARAMS = 6
$EXIT_TIMEOUT = 7
$EXIT_ALREADY_MOUNTED = 8
$EXIT_UNEXPECTED = 10

# Timeouts and constants
$TASK_TIMEOUT_SEC = 60
$MOUNT_TIMEOUT_SEC = $TASK_TIMEOUT_SEC
$LOG_FILE_NAME = 'mount-wsl-disk.log'

# Make non-terminating errors throw to be caught by try/catch
$ErrorActionPreference = 'Stop'

# Verbose from env var (only if not explicitly set)
if (-not $Verbose) {
    if ($env:MOUNT_WSL_VERBOSE -eq '1') { $Verbose = $true }
}

function Get-Timestamp {
    return (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
}

$script:LogFilePath = $null
function Initialize-Logger {
    try {
        $primary = Join-Path -Path $LogDir -ChildPath $LOG_FILE_NAME
        $fallbackRoot = $env:ProgramData
        if ([string]::IsNullOrEmpty($fallbackRoot)) { $fallbackRoot = 'C:\\ProgramData' }
        $fallbackDir = Join-Path -Path $fallbackRoot -ChildPath 'mount-wsl-disk'
        $fallback = Join-Path -Path $fallbackDir -ChildPath $LOG_FILE_NAME
        foreach ($candidate in @($primary, $fallback)) {
            try {
                $parent = Split-Path -Path $candidate -Parent
                if (-not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Force -Path $parent | Out-Null
                }
                if (-not (Test-Path -LiteralPath $candidate)) {
                    New-Item -ItemType File -Force -Path $candidate | Out-Null
                }
                $script:LogFilePath = $candidate
                break
            } catch { }
        }
    } catch { }
}

function Write-Log([string]$Message) {
    $line = "[$(Get-Timestamp)] $Message"
    Write-Host $line
    if ($script:LogFilePath) { Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8 }
}

function Write-ErrorLog([string]$Message) {
    $line = "[$(Get-Timestamp)] $Message"
    # Write to console without marking as a PowerShell error record
    Write-Host $line
    if ($script:LogFilePath) { Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8 }
}

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Find-WSLPath {
    $system32 = Join-Path -Path $env:WINDIR -ChildPath 'System32\\wsl.exe'
    if ($system32 -and (Test-Path -LiteralPath $system32)) { return $system32 }
    $where = (Get-Command wsl -ErrorAction SilentlyContinue)
    if ($where) { return $where.Source }
    return $null
}

function Invoke-Process {
    param(
        [Parameter(Mandatory=$true)] [string]$FilePath,
        [Parameter(Mandatory=$true)] [string[]]$Arguments,
        [Parameter(Mandatory=$true)] [int]$TimeoutSec
    )
    if ($Verbose) { Write-Log ("Running: {0} {1}" -f $FilePath, ($Arguments -join ' ')) }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($Arguments -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $timedOut = -not $proc.WaitForExit($TimeoutSec * 1000)
        if ($timedOut) {
            try { $proc.Kill() } catch { }
        }
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $code = if ($timedOut) { $null } else { $proc.ExitCode }
        if ($Verbose -and $code -ne 0 -and -not $timedOut) {
            Write-Log ("ExitCode={0} TimedOut={1}" -f $code, $timedOut)
        }
        return [pscustomobject]@{
            ExitCode = $code
            TimedOut = $timedOut
            StdOut = $stdout
            StdErr = $stderr
        }
    } catch {
        return [pscustomobject]@{
            ExitCode = $null; TimedOut = $false; StdOut = ''; StdErr = "Exception: $($_.Exception.Message)"
        }
    } finally {
        $proc.Close()
        $proc.Dispose()
    }
}

function Maybe-DumpStreams([string]$Label, [string]$StdOut, [string]$StdErr) {
    if (-not $Verbose) { return }
    if ($StdOut) { Write-Log ("$Label STDOUT BEGIN`n$StdOut`n$Label STDOUT END") }
    if ($StdErr) { Write-Log ("$Label STDERR BEGIN`n$StdErr`n$Label STDERR END") }
}

function Parse-PhysicalDriveNumber([string]$PhysicalDrivePath) {
    $m = [regex]::Match($PhysicalDrivePath, 'PhysicalDrive(\d+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return $null }
    return [int]$m.Groups[1].Value
}

function Test-DiskOnline([int]$DiskNumber) {
    try {
        $d = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
        if ($null -ne $d -and ($d.OperationalStatus -contains 'Online')) { return $true }
        return $false
    } catch { return $false }
}

function Test-VhdAttached([string]$Path) {
    try {
        $v = Get-VHD -Path $Path -ErrorAction SilentlyContinue
        if ($null -ne $v) { return [bool]$v.Attached }
        return $false
    } catch { return $false }
}

function Get-VhdDiskNumber([string]$Path) {
    try {
        $img = Get-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue
        if ($null -eq $img) { return $null }
        $d = $img | Get-Disk -ErrorAction SilentlyContinue
        if ($null -ne $d) { return [int]$d.Number }
        return $null
    } catch { return $null }
}

function Mount-VhdWithTimeout([string]$Path) {
    $psCmd = "Mount-VHD -Path `"$Path`" -PassThru | Get-Disk"
    return Invoke-Process -FilePath 'powershell' -Arguments @('-Command', $psCmd) -TimeoutSec $TASK_TIMEOUT_SEC
}

function Run-SingleAttempt([string]$WslPath, [string]$VhdPath, [string]$PhysicalDrive, [int]$Partition) {
    $timedOutAny = $false
    if ($Verbose) { Write-Log ("Begin attempt with: WSL={0}; VHD={1}; Drive={2}; Partition={3}" -f $WslPath, $VhdPath, $PhysicalDrive, $Partition) }

    # Shutdown WSL first
    Write-Log 'Stopping all running WSL instances...'
    Write-Log 'Invoking: wsl --shutdown'
    $r = Invoke-Process -FilePath $WslPath -Arguments @('--shutdown') -TimeoutSec $TASK_TIMEOUT_SEC
    if ($r.TimedOut) { Write-Log 'wsl --shutdown timed out; continuing to checks/mount.' }
    elseif ($r.ExitCode -ne 0 -and $null -ne $r.ExitCode) { Write-Log ("wsl --shutdown returned {0}; continuing." -f $r.ExitCode) }

    # Disk online?
    if ($Verbose) { Write-Log ("Parsing physical drive path: {0}" -f $PhysicalDrive) }
    $diskNumber = Parse-PhysicalDriveNumber -PhysicalDrivePath $PhysicalDrive
    if ($null -eq $diskNumber) {
        Write-ErrorLog ("Unable to parse disk number from path: {0}" -f $PhysicalDrive)
        return [pscustomobject]@{ ExitCode = $EXIT_INVALID_PARAMS; TimedOut = $timedOutAny }
    }
    if ($Verbose) { Write-Log ("Parsed disk number: {0}" -f $diskNumber) }

    $isOnline = Test-DiskOnline -DiskNumber $diskNumber
    if ($Verbose) { Write-Log ("Disk online: {0}" -f $isOnline) }
    if ($isOnline) {
        Write-Log ("PhysicalDrive{0} is already Online; skipping VHD mount step." -f $diskNumber)
    }
    else {
        # VHD already attached?
        if ($Verbose) { Write-Log "Checking if VHD is already attached..." }
        $attached = Test-VhdAttached -Path $VhdPath
        if ($Verbose) { Write-Log ("VHD attached: {0}" -f $attached) }
        if ($attached) {
            if ($Verbose) { Write-Log 'VHD file is already attached; deriving disk number from image...' }
            $vhdDisk = Get-VhdDiskNumber -Path $VhdPath
            if ($null -ne $vhdDisk) {
                if ($Verbose) { Write-Log ("Resolved VHD disk number: {0}" -f $vhdDisk) }
                $PhysicalDrive = ("\\.\\PhysicalDrive{0}" -f $vhdDisk)
                if ($Verbose) { Write-Log ("Overriding PhysicalDrive for mount to: {0}" -f $PhysicalDrive) }
            }
            Start-Sleep -Seconds 1
        }
        else {
            Write-Log ("Mounting VHD: {0}" -f $VhdPath)
            Write-Log ('Invoking: powershell -Command "Mount-VHD -Path ''{0}'' -PassThru | Get-Disk"' -f $VhdPath)
            $mv = Mount-VhdWithTimeout -Path $VhdPath
            if ($mv.TimedOut) { Write-ErrorLog 'Failed to mount VHD: operation timed out.'; return [pscustomobject]@{ ExitCode = $EXIT_TIMEOUT; TimedOut = $true } }
            if ($mv.ExitCode -ne 0 -and $null -ne $mv.ExitCode) { Write-ErrorLog ("Failed to mount VHD: {0}" -f $mv.StdErr); return [pscustomobject]@{ ExitCode = $EXIT_MOUNT_GENERIC_FAIL; TimedOut = $timedOutAny } }
            Write-Log 'VHD mounted successfully. Deriving disk number from image...'
            $vhdDisk = Get-VhdDiskNumber -Path $VhdPath
            if ($null -ne $vhdDisk) {
                if ($Verbose) { Write-Log ("Resolved VHD disk number: {0}" -f $vhdDisk) }
                $PhysicalDrive = ("\\.\\PhysicalDrive{0}" -f $vhdDisk)
                if ($Verbose) { Write-Log ("Overriding PhysicalDrive for mount to: {0}" -f $PhysicalDrive) }
            }
            Start-Sleep -Seconds 1
        }
    }

    # Extra safety: shutdown again before host-side mount (non-fatal)
    if ($Verbose) { Write-Log 'Ensuring WSL is stopped before host-side mount...' }
    Write-Log 'Invoking: wsl --shutdown'
    $r2 = Invoke-Process -FilePath $WslPath -Arguments @('--shutdown') -TimeoutSec $TASK_TIMEOUT_SEC
    if ($r2.TimedOut) { Write-Log 'wsl --shutdown timed out; proceeding with mount.' }
    elseif ($r2.ExitCode -ne 0 -and $null -ne $r2.ExitCode) { Write-Log ("wsl --shutdown returned {0}; proceeding." -f $r2.ExitCode) }

    # Detach VHD before WSL mount to avoid sharing violations
    if (Test-VhdAttached -Path $VhdPath) {
        if ($Verbose) { Write-Log ("Detaching VHD before WSL mount: {0}" -f $VhdPath) }
        try { 
            Dismount-VHD -Path $VhdPath -ErrorAction SilentlyContinue 
            if ($Verbose) { Write-Log 'VHD detached successfully.' }
        } catch { 
            if ($Verbose) { Write-Log 'VHD detach failed; proceeding anyway.' }
        }
        Start-Sleep -Seconds 1
    }

    # Host-side mount using the more reliable --vhd method
    Write-Log ("Mounting physical Linux disk using VHD method: {0} partition {1}..." -f $VhdPath, $Partition)
    Write-Log ("Invoking: {0} --mount --vhd {1} --partition {2}" -f $WslPath, $VhdPath, $Partition)
    $rm = Invoke-Process -FilePath $WslPath -Arguments @('--mount', '--vhd', $VhdPath, '--partition', "$Partition") -TimeoutSec $MOUNT_TIMEOUT_SEC

    if ($Verbose) { Write-Log 'WSL mount completed. Waiting 3 seconds for system to release locks...' }
    Start-Sleep -Seconds 3

    $combined = ("{0}`n{1}" -f ($rm.StdOut | Out-String), ($rm.StdErr | Out-String)).Trim()
    $lower = $combined.ToLowerInvariant()

    if ($rm.TimedOut) { Write-ErrorLog 'wsl --mount --vhd timed out.'; return [pscustomobject]@{ ExitCode = $EXIT_TIMEOUT; TimedOut = $true } }

    if ($Verbose -or ($rm.ExitCode -ne 0 -and $null -ne $rm.ExitCode)) { Maybe-DumpStreams -Label 'Mount' -StdOut $rm.StdOut -StdErr $rm.StdErr }

    if ($lower -like '*the disk was successfully mounted*') { Write-Log 'Host reported successful mount.'; return [pscustomobject]@{ ExitCode = $EXIT_SUCCESS; TimedOut = $timedOutAny } }
    if ($rm.ExitCode -eq 0) { Write-Log 'WSL disk mount completed successfully.'; return [pscustomobject]@{ ExitCode = $EXIT_SUCCESS; TimedOut = $timedOutAny } }
    if ($lower -like '*already*mounted*') { Write-Log 'WSL reports device already mounted; treating as no-op.'; return [pscustomobject]@{ ExitCode = $EXIT_ALREADY_MOUNTED; TimedOut = $timedOutAny } }

    if ($lower -like '*not found*' -or $lower -like '*could not find*' -or $lower -like '*cannot find*' -or $lower -like '*no such file*') {
        Write-ErrorLog ("Target disk/partition not found. Details: {0}" -f $combined)
        return [pscustomobject]@{ ExitCode = $EXIT_TARGET_NOT_FOUND; TimedOut = $timedOutAny }
    }
    if ($lower -like '*invalid*' -or $lower -like '*unknown option*' -or $lower -like '*usage:*') {
        Write-ErrorLog ("Invalid parameters passed to wsl --mount. Details: {0}" -f $combined)
        return [pscustomobject]@{ ExitCode = $EXIT_INVALID_PARAMS; TimedOut = $timedOutAny }
    }

    # Mount failed
    $exitText = if ($null -eq $rm.ExitCode) { 'unknown' } else { $rm.ExitCode }
    Write-ErrorLog ("wsl --mount --vhd failed. Exit: {0}. Details: {1}" -f $exitText, $combined)
    return [pscustomobject]@{ ExitCode = $EXIT_MOUNT_GENERIC_FAIL; TimedOut = $timedOutAny }
}

# Initialize logger and perform early admin check
Initialize-Logger
if ($script:LogFilePath) { Write-Log ("Log file path: {0}" -f $script:LogFilePath) } else { Write-Log 'No writable log file found; logging to console only.' }
if ($Verbose) { Write-Log ("Script path: {0}" -f $PSCommandPath) }
Write-Log ("Effective params: VhdPath={0}; PhysicalDrive={1}; Partition={2}; LogDir={3}" -f $VhdPath, $PhysicalDrive, $Partition, $LogDir)

if (-not (Test-IsAdmin)) {
    Write-ErrorLog 'Administrator privileges are required.'
    exit $EXIT_ADMIN_REQUIRED
}

# Locate WSL
$wslPath = Find-WSLPath
if (-not $wslPath) {
    Write-ErrorLog 'WSL is not installed or not available in PATH.'
    exit $EXIT_WSL_MISSING
}
if ($Verbose) { Write-Log ("WSL path: {0}" -f $wslPath) }

# Retry loop: up to 3 attempts, retry only on timeouts
$maxAttempts = 3
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    Write-Log ("Starting mount attempt {0} of {1}..." -f $attempt, $maxAttempts)
    if ($Verbose) { Write-Log ("Plan: 1) wsl --shutdown 2) Ensure VHD attached: {0} 3) wsl --mount --vhd {0} --partition {1}" -f $VhdPath, $Partition) }
    try {
        if ($Verbose) { Write-Log 'Calling Run-SingleAttempt...' }
        $result = Run-SingleAttempt -WslPath $wslPath -VhdPath $VhdPath -PhysicalDrive $PhysicalDrive -Partition $Partition
        $exitCode = $result.ExitCode
        $timedOut = $result.TimedOut
        if ($Verbose) { Write-Log ("Run-SingleAttempt returned: ExitCode={0}; TimedOut={1}" -f $exitCode, $timedOut) }
    }
    catch {
        Write-ErrorLog ("Unexpected exception during attempt: {0}" -f $_.Exception.Message)
        exit $EXIT_UNEXPECTED
    }

    if ($exitCode -eq $EXIT_SUCCESS -or $exitCode -eq $EXIT_ALREADY_MOUNTED) { exit $exitCode }
    if ($timedOut -or $exitCode -eq $EXIT_TIMEOUT) {
        if ($attempt -lt $maxAttempts) {
            Write-Log 'A step timed out. Retrying entire sequence from the beginning in 2 seconds...'
            Start-Sleep -Seconds 2
            continue
        }
        Write-ErrorLog 'All attempts exhausted due to timeouts.'
        exit $EXIT_TIMEOUT
    }
    # Non-timeout failure: do not retry
    exit $exitCode
}

# Should not reach here
exit $EXIT_UNEXPECTED
