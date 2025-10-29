Mount-VHD -Path "E:\wsl_data.vhdx" -PassThru | Get-Disk
Start-Sleep -Seconds 1
C:\WINDOWS\System32\wsl.exe --mount \\.\PhysicalDrive2 --partition 2
