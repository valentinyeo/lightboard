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
