# SSD Backup

Jednoduché skripty, které přes [`restic`](https://restic.net) zálohují tvoje **osobní
složky na připojený externí SSD** – verzovaně, deduplikovaně a šifrovaně. Spouštět se
dají opakovaně: co je beze změny, se znovu nenahrává. Nic se přitom **nemaže** – i
smazané/staré verze zůstávají v historii, dokud je sám neprořízneš (`--prune`).
Cloudové složky (ownCloud, Nextcloud, iCloud, Dropbox…) se **nezálohují**.

Každý skript má průvodce s barevným výstupem: spusť ho bez argumentů a provede tě
krok za krokem – **zkontroluje prerekvizity** (restic, awk, lsblk…), najde připojené
disky a nabídne zkušební běh.

by [@ret3030](https://github.com/ret3030)

| Systém | Skript | Nástroj |
|--------|--------|---------|
| Linux | `backup-linux.sh` | `restic` |
| macOS | `backup-macos.sh` | `restic` |
| Windows | `backup-windows.ps1` | `restic` |

### Instalace resticu

```bash
sudo pacman -S restic      # Arch
sudo apt install restic    # Debian/Ubuntu
brew install restic        # macOS
winget install restic.restic   # Windows
```

## Linux

```bash
./backup-linux.sh                         # průvodce (najde disky, umí i ty nepřipojené)
./backup-linux.sh /media/$USER/MujSSD     # cíl zadaný cestou
./backup-linux.sh --uuid 1234-ABCD        # cíl podle UUID – když není připojený, připojí ho
./backup-linux.sh --label "WD SSD"        # cíl podle štítku disku
./backup-linux.sh --uuid 1234-ABCD --save # zapamatovat disk do ~/.config/ssd-backup/
./backup-linux.sh --yes                   # bez dotazů; použije zapamatovaný disk (cron)
./backup-linux.sh /mnt/ssd --dry-run      # nic nezapíše, jen ukáže
./backup-linux.sh /mnt/ssd --snapshots    # vypsat historii záloh
./backup-linux.sh /mnt/ssd --prune=10     # po záloze ponechat jen posledních 10 snapshotů
./backup-linux.sh --umount                # po dokončení disk odpojit (--poweroff = i uspat)
./backup-linux.sh --wipe                  # rychlý wipe SSD (TRIM) + nový oddíl + mkfs, pak záloha
```

Linuxová verze si **cíl umí najít a připojit sama** podle `UUID` nebo štítku, takže
stejný příkaz (i `--save` + `--yes` v cronu) funguje na jakémkoli počítači, kam ten
disk zapojíš. Pozná taky, když SSD **není připojený** a cesta míří jen do prázdné
složky na systémovém disku / v ramdisku – v tom případě se zastaví (s `--yes` skončí
chybou, aby cron nezálohoval naslepo).

### Vlastní zdroje / výjimky bez editace skriptu

```
~/.config/ssd-backup/sources.txt      # jedna cesta na řádek (přidá se k SOURCES)
~/.config/ssd-backup/excludes.txt     # jeden vzor na řádek (přidá se k EXCLUDES)
~/.config/ssd-backup/target.conf      # UUID= / LABEL= zapamatovaného disku (píše --save)
~/.config/ssd-backup/restic-password  # heslo repozitáře – vygeneruje se samo při 1. běhu
```

`#` je komentář, `~/` se rozvine na domovskou složku.

**Heslo repozitáře je jediný klíč k datům – bez něj je záloha nenávratně ztracená.**
Skript ho při prvním běhu sám vygeneruje a uloží do `restic-password` (čte ho jen
majitel souboru). Udělej si jeho kopii i mimo tenhle počítač (heslenka, trezor…).

### `--wipe` (rychlý „chytrý" wipe SSD)

`blkdiscard` (TRIM celého disku, prakticky okamžité) → nová GPT s jedním oddílem →
`mkfs.ext4` (nebo `mkfs.exfat` přes `--wipe=exfat`) → volitelně hned záloha.
Vyžaduje potvrzení (opíšeš štítek disku + „ano"), **nikdy neběží s `--yes`** a odmítne
disk, který nese systémové oddíly nebo není výměnný. Potřebuje `blkdiscard`,
`sgdisk`/`parted`, `mkfs.*` a práva roota (`sudo`). Restic funguje na libovolném
souborovém systému (exFAT/ext4/NTFS) stejně dobře – wipe je jen pro pohodlí/rychlost,
ne kvůli omezením zálohy.

### Návratový kód

`0` = záloha proběhla · `1` = restic hlásil chybu · `2` = špatné použití.
(Windows navíc bere resticův kód `3` – snapshot vznikl, ale některé soubory nešly
přečíst – jako úspěch s varováním.)

## macOS

```bash
./backup-macos.sh                         # průvodce
./backup-macos.sh /Volumes/MujSSD
./backup-macos.sh /Volumes/MujSSD --dry-run
./backup-macos.sh /Volumes/MujSSD --yes
./backup-macos.sh /Volumes/MujSSD --snapshots
./backup-macos.sh /Volumes/MujSSD --prune=10
```

## Windows

```powershell
.\backup-windows.ps1                       # průvodce
.\backup-windows.ps1 -Dest E:\
.\backup-windows.ps1 -Dest E:\ -DryRun
.\backup-windows.ps1 -Dest E:\ -Yes        # bez dotazů (Plánovač úloh)
.\backup-windows.ps1 -Dest E:\ -Snapshots
.\backup-windows.ps1 -Dest E:\ -Prune 10
.\backup-windows.ps1 -Dest E:\ -NoVss      # bez stínové kopie
```

**Spouštěj PowerShell jako správce.** Skript pak zálohuje přes stínovou kopii svazku
(VSS, restic `--use-fs-snapshot`), takže projdou i soubory, které má zrovna otevřená
jiná aplikace – pošta, prohlížeč, databáze. Bez práv správce se takové soubory
přeskočí a restic skončí kódem `3` (snapshot vznikne, ale je neúplný).

Windowsová verze zálohuje **celý uživatelský profil** (`C:\Users\<ty>`) a smetí
odřezává výjimkami – `AppData\Local` a `AppData\LocalLow` (cache, instalátory,
balíčky), skryté legacy junction pointy v kořeni profilu (`My Documents`,
`Local Settings`, `Cookies`… – jdou jen do prázdna a hlásí „Access denied"),
registrové hive a cloudové složky. Data mimo profil (jiná písmena disků) si přidej
do `$Sources` nahoře ve skriptu.

Kdyby to blokovala execution policy:

```powershell
powershell -ExecutionPolicy Bypass -File .\backup-windows.ps1
```

> `backup-windows.ps1` je uložený v **UTF-8 s BOM** – Windows PowerShell 5.1 čte
> `.ps1` bez BOM v ANSI codepage a diakritika mu rozbije parser. Když soubor
> upravuješ, zachovej kódování (`Set-Content -Encoding UTF8`, ve VS Code
> „UTF-8 with BOM").

## Kam se data ukládají

```
<SSD>/backup/<hostname>-<user>/restic-repo/    # restic repozitář (šifrovaný, binární)
```

Obsah repozitáře se prohlíží a obnovuje přes restic, ne přímým procházením souborů:

```bash
restic -r <SSD>/backup/<hostname>-<user>/restic-repo snapshots           # historie
restic -r <SSD>/backup/<hostname>-<user>/restic-repo restore latest --target /kam
```

(potřebuje `RESTIC_PASSWORD_FILE=~/.config/ssd-backup/restic-password`, případně na
jiném počítači stejné heslo z tohoto souboru)

## Co se zálohuje / nezálohuje

- **Zálohuje se:** složky v proměnné `SOURCES` / `$Sources` na začátku skriptu. Na
  Linuxu/macOS jsou to běžné osobní složky (Dokumenty, Plocha, Obrázky, Video, Hudba,
  Stažené, Projects a vybrané dotfiles / `.config`), na Windows **celý profil**.
- **Nezálohuje se:** `owncloud`, `Nextcloud`, `iCloud Drive`, `OneDrive`,
  `Dropbox`, `Google Drive`, cache, koš, `node_modules`, `__pycache__`, build
  složky… – viz `EXCLUDES` / `$ExcludeDirs`.

Oba seznamy si nahoře ve skriptu uprav podle sebe – na Linuxu/macOS je navíc můžeš
rozšířit přes `~/.config/ssd-backup/{sources,excludes}.txt` bez zásahu do skriptu.

## Poznámky

- Restic **nikdy nic nemaže sám** – každý běh je nový snapshot, staré verze i
  smazané soubory zůstávají v historii. Chceš uklidit místo? `--prune=N` po záloze
  ponechá jen posledních `N` snapshotů (výchozí 10 při použití bez čísla).
- Díky deduplikaci na úrovni bloků zabírají opakované zálohy na disku jen zlomek
  původní velikosti, i když se soubory přejmenují nebo mírně změní.
- První běh může trvat dlouho (čte se vše), další jsou rychlé (jen změny).

## Licence

MIT – viz [LICENSE](LICENSE).
