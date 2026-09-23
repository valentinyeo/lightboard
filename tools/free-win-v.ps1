<#
.SYNOPSIS
    Frees Win+V from Explorer so lightboard's RegisterHotKey(Win+V) can receive it.

.DESCRIPTION
    By default, Windows Explorer reserves Win+V for the built-in clipboard
    history UI, which means a normal RegisterHotKey(MOD_WIN, 'V') call from
    another process never fires. The documented fix is to add "V" to
    HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\DisabledHotkeys
    (a REG_SZ value; each character in the string disables one Win+<char>
    shortcut) and restart Explorer so it re-reads the setting.

    This script is idempotent: running it repeatedly will not duplicate "V"
    in the value, and running -Undo repeatedly will not error if "V" is
    already absent.

    Lightboard itself never edits the registry - this script exists so a
    human explicitly opts in, per project policy.

.PARAMETER Undo
    Remove "V" from DisabledHotkeys (restoring Explorer's default Win+V
    clipboard history behavior) and restart Explorer.

.PARAMETER NoRestart
    Skip restarting explorer.exe after changing the registry value. The
    change will not take effect until Explorer restarts (or you sign out
    and back in), so only use this if you plan to restart Explorer yourself.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\free-win-v.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\free-win-v.ps1 -Undo
#>
[CmdletBinding()]
param(
    [switch]$Undo,
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'

$regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$valueName = 'DisabledHotkeys'

if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}

$existing = $null
try {
    $existing = (Get-ItemProperty -Path $regPath -Name $valueName -ErrorAction Stop).$valueName
} catch {
    $existing = $null
}

if ($Undo) {
    if ([string]::IsNullOrEmpty($existing)) {
        Write-Host "DisabledHotkeys is already empty/absent - nothing to undo." -ForegroundColor Yellow
        exit 0
    }

    if ($existing.IndexOf('V') -lt 0 -and $existing.IndexOf('v') -lt 0) {
        Write-Host "DisabledHotkeys ('$existing') does not contain V - nothing to undo." -ForegroundColor Yellow
        exit 0
    }

    $newValue = ($existing.ToCharArray() | Where-Object { $_ -ne 'V' -and $_ -ne 'v' }) -join ''

    if ([string]::IsNullOrEmpty($newValue)) {
        Remove-ItemProperty -Path $regPath -Name $valueName -ErrorAction SilentlyContinue
        Write-Host "Removed DisabledHotkeys (was '$existing') - Win+V restored to Explorer's clipboard history." -ForegroundColor Green
    } else {
        Set-ItemProperty -Path $regPath -Name $valueName -Value $newValue -Type String
        Write-Host "Updated DisabledHotkeys: '$existing' -> '$newValue' - Win+V restored to Explorer's clipboard history." -ForegroundColor Green
    }
} else {
    if (-not [string]::IsNullOrEmpty($existing) -and ($existing.IndexOf('V') -ge 0 -or $existing.IndexOf('v') -ge 0)) {
        Write-Host "DisabledHotkeys already contains V ('$existing') - Win+V is already free for lightboard." -ForegroundColor Yellow
        if (-not $NoRestart) {
            exit 0
        }
    } else {
        $newValue = if ([string]::IsNullOrEmpty($existing)) { 'V' } else { "$existing" + 'V' }
        Set-ItemProperty -Path $regPath -Name $valueName -Value $newValue -Type String -Force
        if ([string]::IsNullOrEmpty($existing)) {
            Write-Host "Created DisabledHotkeys = '$newValue'." -ForegroundColor Green
        } else {
            Write-Host "Updated DisabledHotkeys: '$existing' -> '$newValue'." -ForegroundColor Green
        }
    }
}

if ($NoRestart) {
    Write-Host "Skipping Explorer restart (-NoRestart). The change will not take effect until Explorer restarts or you sign out/in." -ForegroundColor Yellow
    exit 0
}

Write-Host "Restarting Explorer for the change to take effect..." -ForegroundColor Cyan
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Start-Process explorer.exe
Write-Host "Done. Restart lightboard (or wait for it to re-register Win+V on next launch)." -ForegroundColor Green
