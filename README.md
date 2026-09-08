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
./backup-linux.sh                         # průvodce
./backup-linux.sh /media/$USER/MujSSD     # rovnou s cílem
./backup-linux.sh /mnt/ssd --dry-run      # nic nezapíše, jen ukáže
./backup-linux.sh /mnt/ssd --no-mirror    # nemaže na SSD to, co jsi smazal doma
./backup-linux.sh /mnt/ssd --yes          # bez dotazů (cron)
```

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

Oba seznamy si nahoře ve skriptu uprav podle sebe.

## Poznámky

- Výchozí režim je **zrcadlo** (`--delete` / `/MIR`): co smažeš doma, zmizí i na
  SSD. Nechceš to? Použij `--no-mirror` / `-NoMirror` (průvodce se ptá).
- Maže se jen uvnitř `<SSD>/backup/<hostname>-<user>/`, nikde jinde na disku.
- První běh může trvat dlouho, další jsou rychlé (přenáší se jen změny).

## Licence

MIT – viz [LICENSE](LICENSE).
