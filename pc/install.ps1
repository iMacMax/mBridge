# Installs mBridge on a Windows PC: compiles it, starts it, and sets it to start at login.
# Run it with one command (PowerShell):
#   irm https://raw.githubusercontent.com/iMacMax/mBridge/main/pc/install.ps1 | iex
$ErrorActionPreference = "Stop"

$repo = "https://raw.githubusercontent.com/iMacMax/mBridge/main/pc"
$dir = Join-Path $env:LOCALAPPDATA "mBridge"
$exe = Join-Path $dir "mBridge.exe"
$source = Join-Path $dir "Program.cs"
$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"

New-Item -ItemType Directory -Force $dir | Out-Null
Get-Process mBridge -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

# next to this script when run from a download, otherwise fetched from GitHub
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "Program.cs"))) {
    Copy-Item (Join-Path $PSScriptRoot "Program.cs") $source -Force
} else {
    Invoke-WebRequest "$repo/Program.cs" -OutFile $source -UseBasicParsing
}

& $csc /nologo /target:winexe /optimize "/out:$exe" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll $source
if ($LASTEXITCODE -ne 0) { throw "Build failed" }

# lets the Mac reach this PC; skipped quietly when not running as administrator
try {
    Remove-NetFirewallRule -DisplayName "mBridge" -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "mBridge" -Direction Inbound -Program $exe -Action Allow -Profile Private,Domain | Out-Null
} catch { }

Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name mBridge -Value "`"$exe`""
Start-Process $exe
Write-Host "mBridge installed. Look for the monitor icon in the system tray."
Write-Host "If Windows asks about the firewall, allow it on Private networks."
