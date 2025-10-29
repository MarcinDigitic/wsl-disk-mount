HELP_TEXT = """
mount-wsl-disk.py
------------------

Purpose
  Mount a Windows host physical Linux disk (for WSL) using a VHD file.
  The script is intended to run at user logon or manually, and it handles
  shutdown of WSL, attachment of the VHD file, and host-side mounting via
  "wsl --mount".

Key requirements
  - Administrator privileges are REQUIRED to run this script.
  - Mounting the WSL disk is ONLY possible when WSL is shut down. The script
    issues "wsl --shutdown" at the start of each attempt.

How it works (per attempt)
  1) Stop all WSL instances:             wsl --shutdown
  2) Ensure VHD is attached:             Mount-VHD (if not already attached)
  3) Mount the disk to WSL:              wsl --mount \\ .\\PhysicalDriveN --partition P

Reliability
  - Each critical step has a timeout of {TASK_TIMEOUT_SEC} seconds by default.
  - If any step times out, the entire sequence is retried from scratch,
    up to 3 attempts. Non-timeout failures do not trigger retries.

Configuration (edit constants in this file)
  - VHD_PATH:        path to the VHDX file (e.g., E:\\wsl_data.vhdx)
  - PHYSICAL_DRIVE:  target drive path (e.g., \\ .\\PhysicalDrive2)
  - PARTITION:       target partition number (e.g., 2)
  - TASK_TIMEOUT_SEC: per-step timeout in seconds (default: {TASK_TIMEOUT_SEC})
  - LOG_FILE_NAME:   log file name (default: {LOG_FILE_NAME})
  - LOG_DIR:         log directory (default: {LOG_DIR})

These values may be overridden via command-line options:
  --vhd-path PATH          Override VHD path (default: {VHD_PATH})
  --physical-drive PATH    Override physical drive (default: {PHYSICAL_DRIVE})
  --partition N            Override partition number (default: {PARTITION})
  --verbose                Enable verbose logging (also via MOUNT_WSL_VERBOSE=1)
  --log-dir PATH           Override log directory (default: {LOG_DIR})

Environment variables
  - MOUNT_WSL_VERBOSE=1   Enable verbose logging of command outputs.

Exit codes
  {EXIT_SUCCESS:>2}  Success
  {EXIT_WSL_MISSING:>2}  WSL not found
  {EXIT_MOUNT_GENERIC_FAIL:>2}  Mount failed
  {EXIT_TARGET_NOT_FOUND:>2}  Disk/partition not found
  {EXIT_ADMIN_REQUIRED:>2}  Admin rights required
  {EXIT_INVALID_PARAMS:>2}  Invalid parameters
  {EXIT_TIMEOUT:>2}  Operation timed out
  {EXIT_ALREADY_MOUNTED:>2}  Already mounted
  {EXIT_UNEXPECTED:>2}  Unexpected error

Usage
  - Show help:
      python {script_name} --help

  - Normal run (requires admin privileges):
      python {script_name}

Notes
  - The script logs to C:\\Scripts\\mount-wsl-disk.log when possible, and
    otherwise prints logs to the console only.
"""

import ctypes
import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Optional, Tuple

# Exit codes
EXIT_SUCCESS = 0
EXIT_WSL_MISSING = 2
EXIT_MOUNT_GENERIC_FAIL = 3
EXIT_TARGET_NOT_FOUND = 4
EXIT_ADMIN_REQUIRED = 5
EXIT_INVALID_PARAMS = 6
EXIT_TIMEOUT = 7
EXIT_ALREADY_MOUNTED = 8
EXIT_UNEXPECTED = 10

TASK_TIMEOUT_SEC = 60
MOUNT_TIMEOUT_SEC = TASK_TIMEOUT_SEC
VHD_PATH = r"E:\wsl_data.vhdx"
PHYSICAL_DRIVE = r"\\.\PhysicalDrive2"
PARTITION = 2
VERBOSE = os.environ.get("MOUNT_WSL_VERBOSE", "0") == "1"
LOG_FILE_NAME = "mount-wsl-disk.log"
LOG_DIR = r"C:\\Scripts"


def parse_and_apply_args(argv: list[str]) -> None:
    """Parse CLI args and override global configuration values."""
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--vhd-path", dest="vhd_path", type=str)
    parser.add_argument("--physical-drive", dest="physical_drive", type=str)
    parser.add_argument("--partition", dest="partition", type=int)
    parser.add_argument("--log-dir", dest="log_dir", type=str)
    parser.add_argument(
        "--verbose",
        dest="verbose",
        action="store_true",
        help="Enable verbose logging",
    )
    # Ignore -h/--help here; handled separately before this function is called
    known_args, _unknown = parser.parse_known_args(argv)

    global VHD_PATH, PHYSICAL_DRIVE, PARTITION, VERBOSE, LOG_DIR
    if known_args.vhd_path:
        VHD_PATH = known_args.vhd_path
    if known_args.physical_drive:
        PHYSICAL_DRIVE = known_args.physical_drive
    if known_args.partition is not None:
        PARTITION = known_args.partition
    if known_args.log_dir:
        LOG_DIR = known_args.log_dir
    if known_args.verbose:
        VERBOSE = True


def print_help() -> None:
    """Print extended help and usage information."""
    script_name = Path(sys.argv[0]).name
    print(
        HELP_TEXT.format(
            script_name=script_name,
            TASK_TIMEOUT_SEC=TASK_TIMEOUT_SEC,
            VHD_PATH=VHD_PATH,
            PHYSICAL_DRIVE=PHYSICAL_DRIVE,
            PARTITION=PARTITION,
            LOG_FILE_NAME=LOG_FILE_NAME,
            LOG_DIR=LOG_DIR,
            EXIT_SUCCESS=EXIT_SUCCESS,
            EXIT_WSL_MISSING=EXIT_WSL_MISSING,
            EXIT_MOUNT_GENERIC_FAIL=EXIT_MOUNT_GENERIC_FAIL,
            EXIT_TARGET_NOT_FOUND=EXIT_TARGET_NOT_FOUND,
            EXIT_ADMIN_REQUIRED=EXIT_ADMIN_REQUIRED,
            EXIT_INVALID_PARAMS=EXIT_INVALID_PARAMS,
            EXIT_TIMEOUT=EXIT_TIMEOUT,
            EXIT_ALREADY_MOUNTED=EXIT_ALREADY_MOUNTED,
            EXIT_UNEXPECTED=EXIT_UNEXPECTED,
        )
    )


def timestamp() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


class Logger:
    def __init__(self) -> None:
        self.log_file: Optional[Path] = self._resolve_log_path()

    def _resolve_log_path(self) -> Optional[Path]:
        primary = Path(LOG_DIR) / LOG_FILE_NAME
        fallback_dir = Path(os.environ.get("ProgramData", r"C:\ProgramData")) / "mount-wsl-disk"
        fallback = fallback_dir / LOG_FILE_NAME
        for candidate in (primary, fallback):
            try:
                candidate.parent.mkdir(parents=True, exist_ok=True)
                # Probe write access
                candidate.touch(exist_ok=True)
                return candidate
            except Exception:
                continue
        return None

    def _format(self, message: str) -> str:
        return f"[{timestamp()}] {message}"

    def info(self, message: str) -> None:
        line = self._format(message)
        print(line)
        if self.log_file:
            try:
                with self.log_file.open("a", encoding="utf-8") as f:
                    f.write(line + "\n")
            except Exception:
                pass

    def error(self, message: str) -> None:
        line = self._format(message)
        print(line, file=sys.stderr)
        if self.log_file:
            try:
                with self.log_file.open("a", encoding="utf-8") as f:
                    f.write(line + "\n")
            except Exception:
                pass


logger = Logger()


def is_admin() -> bool:
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def find_wsl() -> Optional[str]:
    # Prefer System32 to avoid SysWOW64 redirection issues
    system32 = (
        Path(os.environ.get("WINDIR", r"C:\Windows")) / "System32" / "wsl.exe"
    )
    if system32.exists():
        return str(system32)
    return shutil.which("wsl")


def mount_vhd(vhd_path: str) -> Tuple[bool, str, bool]:
    """Mount VHD and return (success, error_message, timed_out)."""
    try:
        # Use PowerShell to mount VHD
        ps_cmd = f'Mount-VHD -Path "{vhd_path}" -PassThru | Get-Disk'
        result = subprocess.run(
            ["powershell", "-Command", ps_cmd],
            capture_output=True,
            text=True,
            timeout=TASK_TIMEOUT_SEC
        )
        
        if result.returncode == 0:
            return True, "", False
        else:
            return False, f"VHD mount failed: {result.stderr}", False
    except subprocess.TimeoutExpired:
        return False, "VHD mount timed out", True
    except Exception as e:
        return False, f"VHD mount exception: {e}", False


def parse_physical_drive_number(physical_drive_path: str) -> Optional[int]:
    r"""Extract the integer disk number from a path like \\.\PhysicalDrive2."""
    match = re.search(r"PhysicalDrive(\d+)$", physical_drive_path, re.IGNORECASE)
    if not match:
        return None
    try:
        return int(match.group(1))
    except ValueError:
        return None


def is_disk_online(disk_number: int) -> Tuple[bool, str]:
    """Return (is_online, error_message). Uses PowerShell Get-Disk."""
    try:
        # Using -ErrorAction SilentlyContinue so missing disk returns Offline
        ps_cmd = (
            f"$d = Get-Disk -Number {disk_number} "
            f"-ErrorAction SilentlyContinue; "
            f"if ($null -ne $d -and ($d.OperationalStatus -contains 'Online')) "
            f"{{ 'Online' }} else {{ 'Offline' }}"
        )
        result = subprocess.run(
            ["powershell", "-Command", ps_cmd],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode != 0:
            return False, result.stderr.strip() or "Get-Disk returned non-zero exit code"
        status = (result.stdout or "").strip().lower()
        return status == "online", ""
    except subprocess.TimeoutExpired:
        return False, "Get-Disk timed out"
    except Exception as ex:
        return False, f"Get-Disk exception: {ex}"


def run_process(exe: str, args: list[str], timeout_sec: int) -> Tuple[Optional[int], bool, str, str]:
    """Run a process returning (exit_code, timed_out, stdout, stderr)."""
    # Log exact command line
    arg_str = " ".join(args)
    logger.info(f"Running: {exe} {arg_str}")
    try:
        proc = subprocess.Popen(
            [exe] + args,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            creationflags=(
                subprocess.CREATE_NO_WINDOW
                if hasattr(subprocess, 'CREATE_NO_WINDOW')
                else 0
            ),
        )
        try:
            stdout, stderr = proc.communicate(timeout=timeout_sec)
            code = proc.returncode
            # Log ExitCode/TimedOut only on verbose or non-success
            if VERBOSE or code not in (0, None):
                code_text = code if code is not None else 'unknown'
                logger.info(
                    f"ExitCode={code_text} TimedOut=False"
                )
            return code, False, stdout or "", stderr or ""
        except subprocess.TimeoutExpired:
            try:
                proc.kill()
            except Exception:
                pass
            stdout, stderr = proc.communicate()
            logger.info("ExitCode=unknown TimedOut=True")
            return None, True, stdout or "", stderr or ""
    except FileNotFoundError:
        return None, False, "", f"Executable not found: {exe}"
    except Exception as ex:
        return None, False, "", f"Exception: {ex}"


def maybe_dump_streams(label: str, stdout: str, stderr: str) -> None:
    if not stdout and not stderr:
        return
    if not VERBOSE:
        return
    if stdout:
        logger.info(f"{label} STDOUT BEGIN\n{stdout}\n{label} STDOUT END")
    if stderr:
        logger.info(f"{label} STDERR BEGIN\n{stderr}\n{label} STDERR END")


def set_exit(code: int, reason: Optional[str] = None) -> None:
    msg = f"Exit code {code}: {reason}" if reason else f"Exit code {code}"
    logger.info(msg)
    # Always exit with the code; Task Scheduler and shells will capture it
    sys.exit(code)


def is_vhd_attached(vhd_path: str) -> Tuple[bool, str, bool]:
    """Return (attached, error_message, timed_out) by querying Get-VHD."""
    try:
        ps_cmd = (
            f"$v = Get-VHD -Path \"{vhd_path}\" -ErrorAction SilentlyContinue; "
            f"if ($null -ne $v) {{ if ($v.Attached) {{ 'True' }} else "
            f"{{ 'False' }} }} else {{ 'False' }}"
        )
        result = subprocess.run(
            ["powershell", "-Command", ps_cmd],
            capture_output=True,
            text=True,
            timeout=TASK_TIMEOUT_SEC,
        )
        if result.returncode != 0:
            return False, result.stderr.strip() or "Get-VHD returned non-zero exit code", False
        attached = (result.stdout or "").strip().lower() == "true"
        return attached, "", False
    except subprocess.TimeoutExpired:
        return False, "Get-VHD timed out", True
    except Exception as ex:
        return False, f"Get-VHD exception: {ex}", False


def run_single_attempt(wsl_path: str) -> Tuple[int, bool]:
    """Execute one full mount attempt. Returns (exit_code, timed_out_any_step)."""
    timed_out_any_step = False
    
    # Always shutdown WSL first before any disk operations
    logger.info("Stopping all running WSL instances...")
    code, timed_out, _out, _err = run_process(wsl_path, ["--shutdown"], timeout_sec=TASK_TIMEOUT_SEC)
    if timed_out:
        timed_out_any_step = True
        logger.info("wsl --shutdown timed out; continuing to checks/mount.")
    elif code not in (0, None):
        logger.info(f"wsl --shutdown returned {code}; continuing.")

    # Check if target physical disk is already online (mounted)
    disk_number = parse_physical_drive_number(PHYSICAL_DRIVE)
    if disk_number is None:
        logger.error(f"Unable to parse disk number from path: {PHYSICAL_DRIVE}")
        return EXIT_INVALID_PARAMS, timed_out_any_step

    online, online_err = is_disk_online(disk_number)
    if online:
        logger.info(f"PhysicalDrive{disk_number} is already Online; skipping VHD mount step.")
    else:
        # Probe if VHD is already attached (and disk perhaps just not yet online)
        attached, vhd_err, vhd_to = is_vhd_attached(VHD_PATH)
        if vhd_to:
            logger.error("Get-VHD probe timed out.")
            return EXIT_TIMEOUT, True
        if attached:
            logger.info("VHD file is already attached; skipping VHD mount step.")
            # Brief settle delay
            time.sleep(1)
        else:
            if online_err:
                logger.info(f"Get-Disk check reported: {online_err or 'unknown error'}. Proceeding to mount VHD.")
            # Mount VHD first
            logger.info(f"Mounting VHD: {VHD_PATH}")
            vhd_success, vhd_error, vhd_timed_out = mount_vhd(VHD_PATH)
            if vhd_timed_out:
                logger.error("Failed to mount VHD: operation timed out.")
                return EXIT_TIMEOUT, True
            if not vhd_success:
                logger.error(f"Failed to mount VHD: {vhd_error}")
                return EXIT_MOUNT_GENERIC_FAIL, timed_out_any_step
            logger.info("VHD mounted successfully. Waiting 1 second...")
            time.sleep(1)

    # Perform host-side mount
    logger.info(f"Mounting physical Linux disk {PHYSICAL_DRIVE} partition {PARTITION}...")
    code, timed_out, out, err = run_process(
        wsl_path,
        ["--mount", PHYSICAL_DRIVE, "--partition", str(PARTITION)],
        timeout_sec=MOUNT_TIMEOUT_SEC,
    )

    # Add delay after WSL mount to allow system to release locks
    logger.info("WSL mount completed. Waiting 3 seconds for system to release locks...")
    time.sleep(3)

    combined = f"{out}\n{err}".strip()
    lower = combined.lower()

    # Only dump stdout/stderr in VERBOSE or on failure/timeout
    if timed_out or (code not in (0, None)) or VERBOSE:
        maybe_dump_streams("Mount", out, err)

    if timed_out:
        logger.error("wsl --mount timed out.")
        return EXIT_TIMEOUT, True

    # Short-circuit success based on known host message or code==0
    if "the disk was successfully mounted" in lower:
        logger.info("Host reported successful mount.")
        return EXIT_SUCCESS, timed_out_any_step

    if code == 0:
        logger.info("WSL disk mount completed successfully.")
        return EXIT_SUCCESS, timed_out_any_step

    if "already" in lower and "mounted" in lower:
        logger.info("WSL reports device already mounted; treating as no-op.")
        return EXIT_ALREADY_MOUNTED, timed_out_any_step

    if any(s in lower for s in ["not found", "could not find", "cannot find", "no such file"]):
        logger.error(f"Target disk/partition not found. Details: {combined}")
        return EXIT_TARGET_NOT_FOUND, timed_out_any_step

    if any(s in lower for s in ["invalid", "unknown option", "usage:"]):
        logger.error(f"Invalid parameters passed to wsl --mount. Details: {combined}")
        return EXIT_INVALID_PARAMS, timed_out_any_step

    logger.error(f"wsl --mount failed. Exit: {'unknown' if code is None else code}. Details: {combined}")
    return EXIT_MOUNT_GENERIC_FAIL, timed_out_any_step


def main() -> int:
    log_msg = (
        f"Log file path: {logger.log_file}"
        if logger.log_file
        else "No writable log file found; logging to console only."
    )
    logger.info(log_msg)

    if not is_admin():
        logger.error("Administrator privileges are required.")
        return EXIT_ADMIN_REQUIRED

    wsl_path = find_wsl()
    if not wsl_path:
        logger.error("WSL is not installed or not available in PATH.")
        return EXIT_WSL_MISSING

    # Retry loop: up to 3 attempts, restart sequence from the beginning on timeout only
    max_attempts = 3
    for attempt in range(1, max_attempts + 1):
        logger.info(f"Starting mount attempt {attempt} of {max_attempts}...")
        exit_code, timed_out = run_single_attempt(wsl_path)
        if exit_code in (EXIT_SUCCESS, EXIT_ALREADY_MOUNTED):
            return exit_code
        if timed_out or exit_code == EXIT_TIMEOUT:
            if attempt < max_attempts:
                logger.info(
                    "A step timed out. Retrying entire sequence "
                    "from the beginning in 2 seconds..."
                )
                time.sleep(2)
                continue
            logger.error("All attempts exhausted due to timeouts.")
            return EXIT_TIMEOUT
        # Non-timeout failure: do not retry
        return exit_code

    # Should not reach here
    return EXIT_UNEXPECTED


if __name__ == "__main__":
    # Help handling occurs before any logging or operations
    if any(arg in ("-h", "--help") for arg in sys.argv[1:]):
        print_help()
        sys.exit(EXIT_SUCCESS)

    # Parse overrides before running main logic
    parse_and_apply_args(sys.argv[1:])

    # Pre-flight: require elevated privileges for normal run
    if not is_admin():
        print("Administrator privileges are required.", file=sys.stderr)
        sys.exit(EXIT_ADMIN_REQUIRED)

    try:
        exit_code = main()
    except Exception as e:
        logger.error(f"Mount script FAILED: {e}")
        exit_code = EXIT_UNEXPECTED
    set_exit(exit_code)
