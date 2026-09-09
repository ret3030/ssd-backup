<#
    Zaloha osobnich souboru na externi SSD (Windows) pres restic.

    Restic uklada verzovane, deduplikovane a sifrovane snapshoty - zadne mazani ani
    prepisovani pri beznem behu. Historie zustava, dokud ji sam neproriznes (-Prune).

    Pouziti (PowerShell):
        .\backup-windows.ps1                          # PRUVODCE - provede te krok za krokem
        .\backup-windows.ps1 -Dest E:\
        .\backup-windows.ps1 -Dest E:\ -DryRun        # jen ukazat, co by se zalohovalo
        .\backup-windows.ps1 -Dest E:\ -Yes           # preskocit dotazy (Planovac uloh)
        .\backup-windows.ps1 -Dest E:\ -Snapshots     # vypsat historii zaloh
        .\backup-windows.ps1 -Dest E:\ -Prune 10      # po zaloze ponechat jen poslednich 10 snapshotu

    Pokud skript nejde spustit kvuli politice, spust jednorazove:
        powershell -ExecutionPolicy Bypass -File .\backup-windows.ps1

    Co se zalohuje: slozky v $Sources nize (vychozi = bezne osobni slozky profilu).
    Co se NEzalohuje: nazvy slozek v $ExcludeDirs (ownCloud, Nextcloud, OneDrive, Dropbox, cache, ...).

    Heslo repozitare: %APPDATA%\ssd-backup\restic-password (pri prvnim behu se vygeneruje samo -
    BEZ NEJ SE K ZALOZE NEDOSTANES, udelej si z nej i vlastni kopii mimo tenhle disk).

    Instalace resticu:  winget install restic.restic   (nebo choco/scoop, viz restic.net)
#>

param(
    [string]$Dest,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Snapshots,
    [int]$Prune = 0
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Nastaveni - klidne si uprav
# --------------------------------------------------------------------------

$Sources = @(
    "$env:USERPROFILE\Documents"
    "$env:USERPROFILE\Desktop"
    "$env:USERPROFILE\Pictures"
    "$env:USERPROFILE\Videos"
    "$env:USERPROFILE\Music"
    "$env:USERPROFILE\Downloads"
    "$env:USERPROFILE\Favorites"
    "$env:USERPROFILE\Projects"
)

# Nazvy slozek, ktere se nikdy nezalohuji (kdekoli ve stromu).
$ExcludeDirs = @(
    "owncloud", "ownCloud", "OwnCloud"
    "Nextcloud", "nextcloud"
    "OneDrive", "OneDriveTemp"
    "Dropbox"
    "Google Drive", "GoogleDrive"
    ".cache", "Cache", "GPUCache", "Code Cache"
    "node_modules", "__pycache__", ".venv", "venv"
    ".gradle", "target", "bin", "obj"
    '$Recycle.Bin', 'System Volume Information'
    "restic-repo"
)

# Vzory souboru, ktere se nezalohuji.
$ExcludeFiles = @(
    "*.tmp", "~*", "*.part", "desktop.ini", "Thumbs.db", "*.lock"
)

$CfgDir   = Join-Path $env:APPDATA 'ssd-backup'
$PassFile = Join-Path $CfgDir 'restic-password'

# --------------------------------------------------------------------------
# Pomucky
# --------------------------------------------------------------------------

function Ask([string]$Question, [string]$Default = 'N') {
    if ($Yes) { return $true }
    $hint = if ($Default -match '[AaYy]') { '[A/n]' } else { '[a/N]' }
    $ans = Read-Host "$Question $hint"
    if ([string]::IsNullOrWhiteSpace($ans)) { $ans = $Default }
    return ($ans -match '^[AaYy]')
}

function Step([string]$m) { Write-Host "`n> $m" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "OK  $m"  -ForegroundColor Green }
function Warn2([string]$m){ Write-Host "!   $m"  -ForegroundColor Yellow }

function Show-Banner {
    $rule = ('=' * 46)
    Write-Host ""
    Write-Host "  $rule"                          -ForegroundColor Cyan
    Write-Host "   * SSD BACKUP  -  osobni soubory (restic)" -ForegroundColor Cyan
    Write-Host "   verzovana, sifrovana zaloha domacich dat" -ForegroundColor DarkGray
    Write-Host "   by @ret3030"                    -ForegroundColor Magenta
    Write-Host "  $rule"                          -ForegroundColor Cyan
    Write-Host ""
}

function Test-Prereqs {
    if (-not (Get-Command restic.exe -ErrorAction SilentlyContinue)) {
        Write-Error "restic nenalezen. Nainstaluj: winget install restic.restic  (nebo viz restic.net)"
    }
    $v = (& restic version) -replace '^restic\s+([0-9.]+).*', '$1'
    Ok "Prerekvizity v poradku (restic $v)."
}

function Ensure-Password {
    if ((Test-Path -LiteralPath $PassFile) -and (Get-Item $PassFile).Length -gt 0) { return }
    New-Item -ItemType Directory -Force -Path $CfgDir | Out-Null
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    [Convert]::ToBase64String($bytes) | Out-File -Encoding ascii -NoNewline $PassFile
    Warn2 "Vygenerovano nove heslo repozitare: $PassFile"
    Warn2 "BEZ NEJ SE K ZALOZE NEDOSTANES. Udelej si jeho kopii i mimo tenhle pocitac."
}

Show-Banner
Test-Prereqs

# --------------------------------------------------------------------------
# Průvodce (když není zadaný -Dest)
# --------------------------------------------------------------------------

if (-not $Dest -and -not $Yes) {
    Write-Host "== Průvodce zálohou ==`n"
    Write-Host "Hledám připojené disky…"

    $drives = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=2 OR DriveType=3" |
        Where-Object { $_.DeviceID -ne $env:SystemDrive } |
        Sort-Object DeviceID

    $list = @($drives)
    if ($list.Count -gt 0) {
        Write-Host "Nalezené jednotky:"
        for ($i = 0; $i -lt $list.Count; $i++) {
            $d = $list[$i]
            $gb = if ($d.Size) { [math]::Round($d.Size / 1GB, 0) } else { '?' }
            $free = if ($d.FreeSpace) { [math]::Round($d.FreeSpace / 1GB, 0) } else { '?' }
            $type = if ($d.DriveType -eq 2) { 'vyměnitelný' } else { 'pevný' }
            "  {0}) {1}\  {2}  {3} GB (volno {4} GB)  {5}" -f ($i + 1), $d.DeviceID, $d.VolumeName, $gb, $free, $type | Write-Host
        }
        Write-Host "  0) zadat cestu ručně"
        $sel = Read-Host "Vyber číslo cíle"
    } else {
        Write-Host "Žádnou externí jednotku jsem nenašel."
        $sel = '0'
    }

    if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $list.Count) {
        $Dest = $list[[int]$sel - 1].DeviceID + '\'
    } else {
        $Dest = Read-Host "Zadej cestu k připojenému SSD (např. E:\ nebo E:\zaloha)"
    }
    Write-Host ""

    if (Ask "Spustit nejdřív zkušební běh (nic nezapíše)?" 'A') {
        $DryRun = $true
    }
    Write-Host ""
}

# --------------------------------------------------------------------------
# Kontroly
# --------------------------------------------------------------------------

if (-not $Dest) {
    Write-Error "Neuvedl jsi cíl. Např.: .\backup-windows.ps1 -Dest E:\"
}
if (-not (Test-Path -LiteralPath $Dest)) {
    Write-Error "Cíl '$Dest' neexistuje nebo není připojený externí disk."
}

$DestFull = (Resolve-Path -LiteralPath $Dest).Path
if ($DestFull -eq "$env:USERPROFILE\" -or $DestFull -eq $env:USERPROFILE -or $DestFull -eq "$env:SystemDrive\") {
    Write-Error "Podezřelý cíl '$DestFull'. Zadej externí disk, ne systémový."
}

$HostDir = "$env:COMPUTERNAME-$env:USERNAME"
$Repo    = Join-Path $DestFull "backup\$HostDir\restic-repo"
New-Item -ItemType Directory -Force -Path (Split-Path $Repo -Parent) | Out-Null

$Existing = @($Sources | Where-Object { Test-Path -LiteralPath $_ })
if ($Existing.Count -eq 0) {
    Write-Error "Nenašel jsem žádnou ze zdrojových složek. Uprav pole `$Sources ve skriptu."
}

Ensure-Password
$env:RESTIC_REPOSITORY   = $Repo
$env:RESTIC_PASSWORD_FILE = $PassFile

Step "Cíl zálohy"
Write-Host "  Repozitář $Repo"
Write-Host "  Zdrojů    $($Existing.Count) složek"

if (-not (Test-Path -LiteralPath (Join-Path $Repo 'config'))) {
    Step "Zakládám nový restic repozitář…"
    & restic init | Out-Null
    Ok "Repozitář založen."
}

if ($Snapshots) {
    Step "Historie záloh"
    & restic snapshots
    exit 0
}

# --------------------------------------------------------------------------
# Záloha přes restic
# --------------------------------------------------------------------------

function Invoke-Backup([bool]$IsDry) {
    $resticArgs = @('backup') + $Existing + @('--tag', 'ssd-backup', '--verbose')
    foreach ($d in $ExcludeDirs)  { $resticArgs += @('--exclude', $d) }
    foreach ($f in $ExcludeFiles) { $resticArgs += @('--exclude', $f) }
    if ($IsDry) { $resticArgs += '--dry-run' }

    Write-Host ("== Záloha" + $(if ($IsDry) { " (ZKUŠEBNÍ BĚH – nic se nezapíše)" } else { "" }) + " ==")
    Write-Host ""

    & restic @resticArgs
    return $LASTEXITCODE
}

if ($DryRun) {
    [void](Invoke-Backup $true)
    Write-Host ""
    if (Ask "Pokračovat teď doopravdy?" 'A') {
        Write-Host ""
    } else {
        Write-Host "Ukončeno. Nic se nezapsalo."
        exit 0
    }
}

$rc = Invoke-Backup $false
if ($rc -eq 0) {
    Ok "Hotovo bez chyb."
    if ($Prune -gt 0) {
        Step "Prořezávám staré snapshoty (ponechám posledních $Prune)…"
        & restic forget --keep-last $Prune --prune
    }
    exit 0
} else {
    Write-Warning "restic hlásí chybu (kód $rc)."
    exit 1
}
