<#
    Jednoduchá záloha osobních souborů na externí SSD (Windows).

    Použití (PowerShell):
        .\backup-windows.ps1                          # PRŮVODCE – provede tě krok za krokem
        .\backup-windows.ps1 -Dest E:\
        .\backup-windows.ps1 -Dest E:\ -NoMirror      # nemazat na SSD soubory smazané ve zdroji
        .\backup-windows.ps1 -Dest E:\ -DryRun        # jen ukázat, co by se dělo
        .\backup-windows.ps1 -Dest E:\ -Yes           # přeskočit dotazy (pro Plánovač úloh apod.)

    Pokud skript nejde spustit kvůli politice, spusť jednorázově:
        powershell -ExecutionPolicy Bypass -File .\backup-windows.ps1

    Co se zálohuje: složky v $Sources níže (výchozí = běžné osobní složky profilu).
    Co se NEzálohuje: názvy složek v $ExcludeDirs (ownCloud, Nextcloud, OneDrive, Dropbox, cache, ...).
#>

param(
    [string]$Dest,
    [switch]$NoMirror,
    [switch]$DryRun,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Nastavení – klidně si uprav
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

# Názvy složek, které se nikdy nezálohují (kdekoli ve stromu).
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
)

# Vzory souborů, které se nezálohují.
$ExcludeFiles = @(
    "*.tmp", "~*", "*.part", "desktop.ini", "Thumbs.db", "*.lock"
)

# --------------------------------------------------------------------------
# Pomůcky
# --------------------------------------------------------------------------

function Ask([string]$Question, [string]$Default = 'N') {
    if ($Yes) { return $true }
    $hint = if ($Default -match '[AaYy]') { '[A/n]' } else { '[a/N]' }
    $ans = Read-Host "$Question $hint"
    if ([string]::IsNullOrWhiteSpace($ans)) { $ans = $Default }
    return ($ans -match '^[AaYy]')
}

# --------------------------------------------------------------------------
# Průvodce (když není zadaný -Dest)
# --------------------------------------------------------------------------

$RunRealAfter = $false

if (-not $Dest -and -not $Yes) {
    Write-Host "== Průvodce zálohou ==`n"
    Write-Host "Hledám připojené disky…"

    # Vypíšeme jednotky typu 'vyměnitelné' a 'pevné' kromě systémové
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

    if (-not $NoMirror) {
        if (-not (Ask "Zrcadlit? (co smažeš doma, zmizí i na SSD)" 'N')) { $NoMirror = $true }
    }

    if (Ask "Spustit nejdřív zkušební běh (nic nezapíše)?" 'A') {
        $DryRun = $true
        $RunRealAfter = $true
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
$Target  = Join-Path $DestFull "backup\$HostDir"
New-Item -ItemType Directory -Force -Path $Target | Out-Null

# --------------------------------------------------------------------------
# Jeden průchod robocopy
# --------------------------------------------------------------------------

function Invoke-Backup([bool]$IsDry) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $suffix = if ($IsDry) { '-dryrun' } else { '' }
    $log = Join-Path $DestFull "backup\backup-$stamp-$HostDir$suffix.log"

    # /E = i podsložky  /XJ = ignorovat junctiony  /R:1 /W:1 = rychlé selhání
    # /NP = bez procent  /NDL = bez výpisu složek  /XA:SH = přeskočit systémové+skryté
    $roboArgs = @('/E', '/XJ', '/R:1', '/W:1', '/NP', '/NDL', '/XA:SH')
    if (-not $NoMirror) { $roboArgs += '/MIR' }
    if ($IsDry)         { $roboArgs += '/L' }
    if ($ExcludeDirs.Count)  { $roboArgs += '/XD'; $roboArgs += $ExcludeDirs }
    if ($ExcludeFiles.Count) { $roboArgs += '/XF'; $roboArgs += $ExcludeFiles }

    $mode = if ($NoMirror) { 'jen přidává' } else { 'zrcadlo (maže i na SSD)' }
    Write-Host ("== Záloha" + $(if ($IsDry) { " (ZKUŠEBNÍ BĚH – nic se nezapíše)" } else { "" }) + " ==")
    Write-Host "Cíl   : $Target"
    Write-Host "Režim : $mode"
    Write-Host "Log   : $log`n"

    $maxRc = 0
    foreach ($src in $Sources) {
        if (-not (Test-Path -LiteralPath $src)) {
            Write-Host "přeskakuji (neexistuje): $src"
            continue
        }
        $name = Split-Path $src -Leaf
        $destDir = Join-Path $Target $name
        Write-Host "--> $src"
        robocopy $src $destDir @roboArgs /TEE /LOG+:$log
        if ($LASTEXITCODE -gt $maxRc) { $maxRc = $LASTEXITCODE }
    }

    Write-Host ""
    if ($maxRc -lt 8) {
        Write-Host "Hotovo. Návratový kód robocopy: $maxRc (0-7 = v pořádku)."
    } else {
        Write-Warning "Robocopy hlásí chyby (kód $maxRc). Zkontroluj log: $log"
    }
    return $maxRc
}

# --------------------------------------------------------------------------
# Běh
# --------------------------------------------------------------------------

if ($DryRun) {
    [void](Invoke-Backup $true)
    if ($RunRealAfter) {
        Write-Host ""
        if (Ask "Pokračovat teď doopravdy?" 'A') {
            $DryRun = $false
            Write-Host ""
        } else {
            Write-Host "Ukončeno. Nic se nezapsalo."
            exit 0
        }
    } else {
        exit 0
    }
}

$rc = Invoke-Backup $false
if ($rc -lt 8) { exit 0 } else { exit 1 }
