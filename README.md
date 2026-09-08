# SSD Backup

Jednoduché skripty, které přes `rsync` / `robocopy` přetáhnou tvoje **osobní
složky na připojený externí SSD**. Spouštět se dají opakovaně – kopíruje se jen
to, co se změnilo. Cloudové složky (ownCloud, Nextcloud, iCloud, Dropbox…) se
**nezálohují**.

Každý skript má průvodce s barevným výstupem: spusť ho bez argumentů a provede tě
krok za krokem – **zkontroluje prerekvizity** (rsync / robocopy, awk, lsblk…),
najde připojené disky, zeptá se na režim a nabídne zkušební běh.

by [@ret3030](https://github.com/ret3030)

| Systém | Skript | Nástroj |
|--------|--------|---------|
| Linux | `backup-linux.sh` | `rsync` |
| macOS | `backup-macos.sh` | `rsync` |
| Windows | `backup-windows.ps1` | `robocopy` |

## Linux

```bash
./backup-linux.sh                         # průvodce (najde disky, umí i ty nepřipojené)
./backup-linux.sh /media/$USER/MujSSD     # cíl zadaný cestou
./backup-linux.sh --uuid 1234-ABCD        # cíl podle UUID – když není připojený, připojí ho
./backup-linux.sh --label "WD SSD"        # cíl podle štítku disku
./backup-linux.sh --uuid 1234-ABCD --save # zapamatovat disk do ~/.config/ssd-backup/
./backup-linux.sh --yes                   # bez dotazů; použije zapamatovaný disk (cron)
./backup-linux.sh /mnt/ssd --dry-run      # nic nezapíše, jen ukáže
./backup-linux.sh /mnt/ssd --no-mirror    # nemaže na SSD to, co jsi smazal doma
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
~/.config/ssd-backup/sources.txt    # jedna cesta na řádek (přidá se k SOURCES)
~/.config/ssd-backup/excludes.txt   # jeden vzor na řádek (přidá se k EXCLUDES)
~/.config/ssd-backup/target.conf    # UUID= / LABEL= zapamatovaného disku (píše --save)
```

`#` je komentář, `~/` se rozvine na domovskou složku. Zálohu uvnitř zálohy vyřadíš
třeba řádkem `BACKUP` nebo `Dokumenty/BACKUP` v `excludes.txt`.

### exFAT / FAT / NTFS jako cíl

Skript souborový systém cíle rozpozná a přizpůsobí se:

- **neposílá** `-A`/`-X` (práva, ACL, xattr tam stejně nejdou), symlinky ukládá jako
  kopie cíle (`-L --safe-links`);
- jede v režimu `--inplace`, což řeší časté chyby `rsync: mkstemp … failed:
  No such file or directory` na exFAT při zápisu tisíců souborů;
- `--modify-window=1` kryje zaokrouhlování časů na FAT (jinak by se kopírovalo vše znovu).

exFAT navíc **nerozlišuje velká/malá písmena**. Pokud disk používáš jen s Linuxem,
spolehlivější je `ext4` – buď ručně, nebo rovnou `./backup-linux.sh --wipe`.

### `--wipe` (rychlý „chytrý" wipe SSD)

`blkdiscard` (TRIM celého disku, prakticky okamžité) → nová GPT s jedním oddílem →
`mkfs.ext4` (nebo `mkfs.exfat` přes `--wipe=exfat`) → volitelně hned záloha.
Vyžaduje potvrzení (opíšeš štítek disku + „ano"), **nikdy neběží s `--yes`** a odmítne
disk, který nese systémové oddíly nebo není výměnný. Potřebuje `blkdiscard`,
`sgdisk`/`parted`, `mkfs.*` a práva roota (`sudo`).

### Návratový kód

`0` = vše přeneseno · `1` = část souborů se nepřenesla (skript to vypíše a ukáže,
kde v logu hledat – žádné falešné „Hotovo bez chyb") · `2` = špatné použití.

## macOS

```bash
./backup-macos.sh                         # průvodce
./backup-macos.sh /Volumes/MujSSD
./backup-macos.sh /Volumes/MujSSD --dry-run
./backup-macos.sh /Volumes/MujSSD --no-mirror
```

Novější macOS má místo `rsync` jen systémový **openrsync** – záloha funguje, ale
nepřenáší ACL, rozšířené atributy ani resource forky. Pro plnou zálohu:
`brew install rsync` – skript si verzi 3.x automaticky vezme a přidá `-aAX`.

## Windows

```powershell
.\backup-windows.ps1                       # průvodce
.\backup-windows.ps1 -Dest E:\
.\backup-windows.ps1 -Dest E:\ -DryRun
.\backup-windows.ps1 -Dest E:\ -NoMirror
.\backup-windows.ps1 -Dest E:\ -Yes       # bez dotazů (Plánovač úloh)
```

Kdyby to blokovala execution policy:

```powershell
powershell -ExecutionPolicy Bypass -File .\backup-windows.ps1
```

## Kam se data ukládají

```
<SSD>/backup/<hostname>-<user>/…      # struktura kopíruje umístění vůči domovské složce
<SSD>/backup/backup-<datum>-….log     # log každého běhu
```

## Co se zálohuje / nezálohuje

- **Zálohuje se:** složky v proměnné `SOURCES` / `$Sources` na začátku skriptu –
  výchozí jsou běžné osobní složky (Dokumenty, Plocha, Obrázky, Video, Hudba,
  Stažené, Projects a vybrané dotfiles / `.config`).
- **Nezálohuje se:** `owncloud`, `Nextcloud`, `iCloud Drive`, `OneDrive`,
  `Dropbox`, `Google Drive`, cache, koš, `node_modules`, `__pycache__`, build
  složky… – viz `EXCLUDES` / `$ExcludeDirs`.

Oba seznamy si nahoře ve skriptu uprav podle sebe – na Linuxu je navíc můžeš rozšířit
přes `~/.config/ssd-backup/{sources,excludes}.txt` bez zásahu do skriptu.

## Poznámky

- Výchozí režim je **zrcadlo** (`--delete` / `/MIR`): co smažeš doma, zmizí i na
  SSD. Nechceš to? Použij `--no-mirror` / `-NoMirror` (průvodce se ptá).
- Maže se jen uvnitř `<SSD>/backup/<hostname>-<user>/`, a to vždy jen v rámci právě
  kopírované zdrojové složky – nikde jinde na disku.
- První běh může trvat dlouho, další jsou rychlé (přenáší se jen změny).
- Na Linuxu se po zápisu volá `sync`; s `--umount` skript disk sám odpojí, takže
  ho můžeš rovnou vytáhnout.

## Licence

MIT – viz [LICENSE](LICENSE).
