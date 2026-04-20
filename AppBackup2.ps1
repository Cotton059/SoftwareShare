<#
.SYNOPSIS
    Automated Windows User Profile Backup and Restore Tool.
.DESCRIPTION
    Dynamically identifies the current user profile, provides a visual drive selection, and executes underlying fault-tolerant compression and extraction.
    Includes auto-elevation to Administrator to bypass C:\ root directory write restrictions.
.AUTHOR
    Everbright
.LINK
    https://github.com/Cotton059/Light-Help
#>

# ==========================================
# Auto-Elevation to Administrator Privileges
# ==========================================
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $startProcessArgs = @{
        FilePath     = "powershell.exe"
        ArgumentList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        Verb         = "RunAs"
        WindowStyle  = "Normal"
    }
    Start-Process @startProcessArgs
    exit
}

# ==========================================
# Core Assemblies & Win32 UI Interop
# ==========================================
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$csharpCode = '
using System;
using System.Runtime.InteropServices;
public class Win32Console {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    
    public static void CenterWindow() {
        IntPtr hWnd = GetConsoleWindow();
        RECT rect;
        GetWindowRect(hWnd, out rect);
        int screenWidth = GetSystemMetrics(0); // SM_CXSCREEN
        int screenHeight = GetSystemMetrics(1); // SM_CYSCREEN
        int windowWidth = rect.Right - rect.Left;
        int windowHeight = rect.Bottom - rect.Top;
        int x = (screenWidth - windowWidth) / 2;
        int y = (screenHeight - windowHeight) / 2;
        SetWindowPos(hWnd, IntPtr.Zero, x, y, 0, 0, 0x0001); // 0x0001 = SWP_NOSIZE
    }
}
'

if (-not ([System.Management.Automation.PSTypeName]'Win32Console').Type) {
    Add-Type -TypeDefinition $csharpCode
}

# ==========================================
# UI Modules
# ==========================================
function Setup-ConsoleWindow {
    $Host.UI.RawUI.WindowTitle = "Application Data Tool V7 - by Everbright"
    
    $windowSize = $Host.UI.RawUI.WindowSize
    $windowSize.Width = 105
    $windowSize.Height = 32
    $Host.UI.RawUI.WindowSize = $windowSize
    
    $bufferSize = $Host.UI.RawUI.BufferSize
    $bufferSize.Width = 105
    $bufferSize.Height = 3000
    $Host.UI.RawUI.BufferSize = $bufferSize

    [Win32Console]::CenterWindow()
}

function Show-Header {
    Clear-Host
    Write-Host "=======================================================================================" -ForegroundColor Cyan
    Write-Host "|                                                                                     |" -ForegroundColor Cyan
    Write-Host "|                   APPLICATION DATA BACKUP & RESTORE TOOL V7                         |" -ForegroundColor White
    Write-Host "|                                                                                     |" -ForegroundColor Cyan
    Write-Host "=======================================================================================" -ForegroundColor Cyan
    Write-Host "| YouTube: Lightspeed Sharing (Please use in conjunction with the official video)     |" -ForegroundColor Magenta
    Write-Host "| GitHub Repo: github.com/Cotton059/Light-Help                                        |" -ForegroundColor Magenta
    Write-Host "=======================================================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Get-DriveSelection {
    param([string]$ActionType)
    
    Write-Host " [$ActionType Mode] Detected available drives:" -ForegroundColor Yellow
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 0 } | Sort-Object Name
    
    $i = 1
    foreach ($drive in $drives) {
        $sizeGB = [math]::Round($drive.Free / 1GB, 2)
        $totalGB = [math]::Round(($drive.Used + $drive.Free) / 1GB, 2)
        Write-Host "   [$i] $($drive.Name):\ (Free: $sizeGB GB / Total: $totalGB GB)" -ForegroundColor Green
        $i++
    }
    Write-Host "   [0] Return to Main Menu" -ForegroundColor DarkGray
    
    $choice = Read-Host "`n Please select the target drive number"
    if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) { return $null }
    
    $index = [int]$choice - 1
    if ($index -ge 0 -and $index -lt $drives.Count) {
        return $drives[$index].Root
    } else {
        Write-Host " Invalid selection!" -ForegroundColor Red
        Start-Sleep -Seconds 1
        return $null
    }
}

function Format-LogPath {
    param([string]$Path)
    if ($Path.Length -gt 75) {
        return "..." + $Path.Substring($Path.Length - 72)
    }
    return $Path.PadRight(75)
}

# ==========================================
# Core Operations
# ==========================================
function Invoke-Backup {
    Show-Header
    $srcDir = $env:USERPROFILE
    Write-Host " --> Locked Backup Source: $srcDir" -ForegroundColor Cyan
    
    $targetDrive = Get-DriveSelection -ActionType "Backup"
    if (-not $targetDrive) { return }
    
    # Updated backup directory and filename logic
    $backupDir = Join-Path -Path $targetDrive -ChildPath "Application Data Backup"
    if (-not (Test-Path -Path $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    
    $currentDate = Get-Date -Format "yyyy-MM-dd"
    $backupFileName = "AppData_$currentDate.zip"
    $backupFile = Join-Path -Path $backupDir -ChildPath $backupFileName
    
    if (Test-Path -Path $backupFile) {
        $confirm = Read-Host "`n WARNING: Backup file [$backupFileName] already exists for today. Overwrite? (Y/N)"
        if ($confirm -notmatch "^[Yy]$") {
            Write-Host " Operation cancelled." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            return
        }
        Remove-Item -Path $backupFile -Force
    }
    
    Write-Host "`n Executing compression sequence. Initializing data stream..." -ForegroundColor Yellow
    Start-Sleep -Seconds 1
    
    try {
        $zip = [System.IO.Compression.ZipFile]::Open($backupFile, [System.IO.Compression.ZipArchiveMode]::Create)
        $srcParentLength = (Get-Item $srcDir).Parent.FullName.Length
        
        $files = Get-ChildItem -Path $srcDir -Recurse -File -Force -ErrorAction SilentlyContinue
        $totalCount = $files.Count
        $current = 0
        $skipped = 0
        
        Write-Host "-----------------------------------------------------------------------------------------" -ForegroundColor DarkGray
        [Console]::ForegroundColor = [ConsoleColor]::DarkGreen
        
        foreach ($file in $files) {
            $current++
            $relativePath = $file.FullName.Substring($srcParentLength)
            if ($relativePath.StartsWith("\") -or $relativePath.StartsWith("/")) {
                $relativePath = $relativePath.Substring(1)
            }
            
            $displayPath = Format-LogPath -Path $relativePath
            [Console]::WriteLine(" [COMPRESS] $displayPath")

            try {
                $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $relativePath, [System.IO.Compression.CompressionLevel]::Optimal)
            } catch {
                $skipped++
            }
        }
        [Console]::ResetColor()
        Write-Host "-----------------------------------------------------------------------------------------" -ForegroundColor DarkGray
        
        Write-Host "`n [SUCCESS] Backup sequence complete." -ForegroundColor Green
        Write-Host " Processed: $current files" -ForegroundColor White
        Write-Host " Skipped:   $skipped system-locked files" -ForegroundColor DarkGray
        Write-Host " Target:    $backupFile" -ForegroundColor Cyan
    } catch {
        [Console]::ResetColor()
        Write-Host "`n [FATAL ERROR] Backup pipeline shattered: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

function Invoke-Restore {
    Show-Header
    $targetDrive = Get-DriveSelection -ActionType "Restore"
    if (-not $targetDrive) { return }
    
    # Updated restore search logic
    $backupDir = Join-Path -Path $targetDrive -ChildPath "Application Data Backup"
    
    if (-not (Test-Path -Path $backupDir)) {
        Write-Host "`n [ERROR] Directory 'Application Data Backup' not found on $($targetDrive)" -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    $backupFiles = Get-ChildItem -Path $backupDir -Filter "*.zip" | Sort-Object LastWriteTime -Descending
    if ($backupFiles.Count -eq 0) {
        Write-Host "`n [ERROR] No backup archives found in $backupDir" -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    Write-Host "`n Available Backups:" -ForegroundColor Yellow
    $bIndex = 1
    foreach ($bFile in $backupFiles) {
        $sizeMB = [math]::Round($bFile.Length / 1MB, 2)
        Write-Host "   [$bIndex] $($bFile.Name) ($sizeMB MB) - Created: $($bFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Green
        $bIndex++
    }
    Write-Host "   [0] Cancel" -ForegroundColor DarkGray

    $bChoice = Read-Host "`n Please select the backup file to restore"
    if ($bChoice -eq '0' -or [string]::IsNullOrWhiteSpace($bChoice)) { return }

    $bIndexChoice = [int]$bChoice - 1
    if ($bIndexChoice -ge 0 -and $bIndexChoice -lt $backupFiles.Count) {
        $backupFile = $backupFiles[$bIndexChoice].FullName
    } else {
        Write-Host " Invalid selection!" -ForegroundColor Red
        Start-Sleep -Seconds 1
        return
    }
    
    $destParent = (Get-Item $env:USERPROFILE).Parent.FullName
    Write-Host "`n --> Target Source:  $backupFile" -ForegroundColor Cyan
    Write-Host " --> Merge Dest:     $destParent" -ForegroundColor Cyan
    Write-Host " NOTE: Extraction will forcefully map and overwrite existing system user data." -ForegroundColor DarkGray
    
    $confirm = Read-Host "`n HIGH RISK: System files will be overwritten! Confirm deploy? (Y/N)"
    if ($confirm -match "^[Yy]$") {
        Write-Host " Initializing extraction matrix..." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($backupFile)
            $totalCount = $zip.Entries.Count
            $current = 0
            $skipped = 0

            Write-Host "-----------------------------------------------------------------------------------------" -ForegroundColor DarkGray
            [Console]::ForegroundColor = [ConsoleColor]::DarkCyan

            foreach ($entry in $zip.Entries) {
                $current++
                $targetPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($destParent, $entry.FullName))
                
                $dir = [System.IO.Path]::GetDirectoryName($targetPath)
                if (-not (Test-Path -Path $dir)) { 
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null 
                }
                
                if ($entry.Name -ne "") { 
                    $displayPath = Format-LogPath -Path $entry.FullName
                    [Console]::WriteLine(" [EXTRACT]  $displayPath")

                    try {
                        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
                    } catch {
                        $skipped++ 
                    }
                }
            }
            [Console]::ResetColor()
            Write-Host "-----------------------------------------------------------------------------------------" -ForegroundColor DarkGray
            
            Write-Host "`n [SUCCESS] Data matrix restored." -ForegroundColor Green
            Write-Host " Protected files skipped: $skipped" -ForegroundColor DarkGray
        } catch {
            [Console]::ResetColor()
            Write-Host "`n [ERROR] Restoration pipeline failure: $($_.Exception.Message)" -ForegroundColor Red
        } finally {
            if ($zip) { $zip.Dispose() }
        }
    } else {
        Write-Host " Operation cancelled." -ForegroundColor Yellow
    }
}

# ==========================================
# Entry Point
# ==========================================
function Main {
    Setup-ConsoleWindow
    
    while ($true) {
        Show-Header
        Write-Host "   [1] Initiate User Profile Backup" -ForegroundColor Cyan
        Write-Host "   [2] Execute System Profile Restore" -ForegroundColor Cyan
        Write-Host "   [0] Terminate Session" -ForegroundColor DarkGray
        
        $choice = Read-Host "`n Awaiting command input"
        
        switch ($choice.Trim()) {
            "1" { Invoke-Backup; Write-Host "`n Press Enter to return to secure menu..."; Read-Host }
            "2" { Invoke-Restore; Write-Host "`n Press Enter to return to secure menu..."; Read-Host }
            "0" { exit }
            default { Write-Host " Unknown command syntax." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}

Main
