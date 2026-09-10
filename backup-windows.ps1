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
        .\backup-windows.ps1 -Dest E:\ -NoVss        # nepouzivat VSS (i kdyz bezis jako admin)

    Pokud skript nejde spustit kvuli politice, spust jednorazove:
        powershell -ExecutionPolicy Bypass -File .\backup-windows.ps1

    Co se zalohuje: cesty v $Sources nize (vychozi = CELY uzivatelsky profil).
    Co se NEzalohuje: $ExcludeDirs (nazvy kdekoli ve stromu), $ExcludePaths (konkretni
    cesty) a $ExcludeFiles (vzory souboru).

    TIP: spust PowerShell jako spravce. Skript pak zalohuje pres stinovou kopii (VSS),
    takze projdou i soubory, ktere ma zrovna otevrene jina aplikace (posta, prohlizec).

    Heslo repozitare: %APPDATA%\ssd-backup\restic-password (pri prvnim behu se vygeneruje samo -
    BEZ NEJ SE K ZALOZE NEDOSTANES, udelej si z nej i vlastni kopii mimo tenhle disk).

    Instalace resticu:  winget install restic.restic   (nebo choco/scoop, viz restic.net)
#>

param(
    [string]$Dest,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Snapshots,
    [int]$Prune = 0,
    [switch]$NoVss
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 posila na konzoli ANSI codepage - bez tohohle by se
# diakritika ve vypisech rozsypala. (Soubor sam musi mit UTF-8 BOM, jinak ho
# 5.1 vubec spravne neprecte.)
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# --------------------------------------------------------------------------
# Nastaveni - klidne si uprav
# --------------------------------------------------------------------------

# Vychozi = CELY uzivatelsky profil. Vsechno osobni je uvnitr; smeti se odrezava
# nize v $ExcludePaths / $ExcludeDirs. Data mimo profil (jina pismena disku,
# spolecne slozky) si pridej sem jako dalsi radky.
$Sources = @(
    "$env:USERPROFILE"
    # "D:\Data"
    # "$env:PUBLIC"
)

# Nazvy slozek, ktere se nikdy nezalohuji (kdekoli ve stromu).
$ExcludeDirs = @(
    "owncloud", "ownCloud", "OwnCloud"
    "Nextcloud", "nextcloud"
    "OneDrive", "OneDriveTemp"          # cloud ma vlastni zalohu; smaz radek, kdyz mas do OneDrive presmerovane Dokumenty
    "Dropbox"
    "Google Drive", "GoogleDrive"
    ".cache", "Cache", "Caches", "GPUCache", "Code Cache", "CacheStorage"
    "Temp", "Crashpad", "CrashDumps"
    "node_modules", "__pycache__", ".venv", "venv"
    ".gradle"
    '$Recycle.Bin', 'System Volume Information'
    "restic-repo"
    # Pozor: tyhle nazvy sedi KDEKOLI ve stromu. Zamerne tu uz NENI "bin" / "obj"
    # / "target" - pri zaloze celeho profilu by vyhodily i osobni slozky.
)

# Konkretni cesty (ne jen nazvy) - smeti a systemove veci, ktere nejdou precist.
$ExcludePaths = @(
    "$env:USERPROFILE\AppData\Local"      # cache, instalatory, balicky: desitky GB, nic osobniho
    "$env:USERPROFILE\AppData\LocalLow"
    "$env:USERPROFILE\AppData\Roaming\Microsoft\Windows\Recent"
    # Skryte legacy junction pointy v korenu profilu: nejdou precist (Access denied)
    # a zacykli pruchod stromem.
    "$env:USERPROFILE\Application Data"
    "$env:USERPROFILE\Local Settings"
    "$env:USERPROFILE\My Documents"
    "$env:USERPROFILE\NetHood"
    "$env:USERPROFILE\PrintHood"
    "$env:USERPROFILE\Recent"
    "$env:USERPROFILE\SendTo"
    "$env:USERPROFILE\Cookies"
    "$env:USERPROFILE\Start Menu"
    "$env:USERPROFILE\Templates"
    "$env:USERPROFILE\Searches"
    # Neco z AppData\Local presto chces? Pridej si to zpatky nahoru do $Sources, napr.:
    # "$env:USERPROFILE\AppData\Local\Thunderbird"
)

# Vzory souboru, ktere se nezalohuji.
$ExcludeFiles = @(
    "*.tmp", "~*", "*.part", "desktop.ini", "Thumbs.db", "*.lock"
    "NTUSER.DAT*", "ntuser.dat*", "*.blf", "*.regtrans-ms"   # registrovy hive, vzdy zamceny
    "hiberfil.sys", "pagefile.sys", "swapfile.sys"
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

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false   # nedostupne (jiny host / non-Windows) -> ber to jako "ne"
    }
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

$UseVss = $false
if (-not $NoVss -and -not $Snapshots) {
    if (Test-Admin) {
        $UseVss = $true
    } else {
        Warn2 "Neběžíš jako správce – bez stínové kopie (VSS). Soubory, které má"
        Warn2 "zrovna otevřené jiná aplikace (pošta, prohlížeč), restic přeskočí."
        Warn2 "Chceš je taky? Spusť PowerShell jako správce."
    }
}

Step "Cíl zálohy"
Write-Host "  Repozitář $Repo"
Write-Host "  Zdrojů    $($Existing.Count)"
if ($UseVss) { Write-Host "  Režim     stínová kopie (VSS) – projdou i zamčené soubory" }

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
    $resticArgs = @('backup') + $Existing + @('--tag', 'ssd-backup', '--verbose', '--exclude-caches')
    # --iexclude = bez ohledu na velikost pismen (Windows tak bere cesty tak jako tak)
    foreach ($d in $ExcludeDirs)  { $resticArgs += @('--iexclude', $d) }
    foreach ($d in $ExcludePaths) { $resticArgs += @('--iexclude', $d) }
    foreach ($f in $ExcludeFiles) { $resticArgs += @('--iexclude', $f) }
    if ($UseVss) { $resticArgs += '--use-fs-snapshot' }
    if ($IsDry)  { $resticArgs += '--dry-run' }

    Write-Host ("== Záloha" + $(if ($IsDry) { " (ZKUŠEBNÍ BĚH – nic se nezapíše)" } else { "" }) + " ==")
    Write-Host ""

    # Out-Host, ne holy vystup: jinak by se cely vypis resticu stal navratovou
    # hodnotou funkce ($rc by bylo pole radku, ne kod) a pri -DryRun by se
    # neukazalo vubec nic.
    & restic @resticArgs | Out-Host
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

# restic: 0 = vse OK, 3 = snapshot vznikl, ale nektere soubory nesly precist
# (zamcene / bez opravneni), 1 = skutecna chyba.
if ($rc -eq 0 -or $rc -eq 3) {
    if ($rc -eq 3) {
        Warn2 "Snapshot vznikl, ale některé soubory nešly přečíst (zamčené nebo bez"
        Warn2 "oprávnění). Výpis je nahoře. Spuštění jako správce jich většinu vyřeší."
    } else {
        Ok "Hotovo bez chyb."
    }
    if ($Prune -gt 0) {
        Step "Prořezávám staré snapshoty (ponechám posledních $Prune)…"
        & restic forget --keep-last $Prune --prune
    }
    exit 0
} else {
    Write-Warning "restic hlásí chybu (kód $rc)."
    exit 1
}
