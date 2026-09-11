#!/usr/bin/env bash
#
#   SSD BACKUP  ·  by @ret3030
#   Záloha osobních souborů na externí SSD (Linux) přes restic. Nezávislá na počítači:
#   cíl se určuje podle UUID / štítku disku a když není připojený, skript ho připojí sám.
#
#   Restic ukládá verzované, deduplikované a šifrované snapshoty – žádné mazání ani
#   přepisování při běžném běhu (na rozdíl od zrcadlení: co smažeš doma, na SSD
#   zůstane v historii, dokud ji sám neprořízneš přes --prune).
#
# Použití:
#   ./backup-linux.sh                          # PRŮVODCE – provede tě krok za krokem
#   ./backup-linux.sh /media/$USER/MujSSD      # cíl zadaný cestou
#   ./backup-linux.sh --uuid 1234-ABCD         # cíl podle UUID (připojí se sám)
#   ./backup-linux.sh --label "WD SSD"         # cíl podle štítku (připojí se sám)
#   ./backup-linux.sh --uuid 1234-ABCD --save  # zapamatovat disk do ~/.config/ssd-backup/
#   ./backup-linux.sh --yes                    # bez dotazů; použije zapamatovaný disk (cron)
#   ./backup-linux.sh --show-target            # který disk je zapamatovaný
#   ./backup-linux.sh --forget                 # zapamatovaný disk smazat
#   ./backup-linux.sh --snapshots              # vypsat historii záloh (bez zálohování)
#
#   Další přepínače:
#   --dry-run           jen ukázat, co by se zálohovalo
#   --umount             po dokončení disk odpojit  (--poweroff = odpojit a uspat)
#   --no-umount           nechat připojený i když ho připojil skript
#   --wipe[=ext4|exfat]  rychlý „chytrý" wipe SSD (TRIM) + nový oddíl + mkfs, pak záloha
#   --prune[=N]           po záloze zahodit staré snapshoty, ponechat posledních N (výchozí 10)
#
# Zdroje:  pole SOURCES níže + ~/.config/ssd-backup/sources.txt  (cesta na řádek)
# Výjimky: pole EXCLUDES níže + ~/.config/ssd-backup/excludes.txt
# Heslo repozitáře: ~/.config/ssd-backup/restic-password (při prvním běhu se vygeneruje samo –
#   BEZ NĚJ SE K ZÁLOZE NEDOSTANEŠ, udělej si z něj i vlastní kopii mimo tenhle disk).
# Návratový kód: 0 = záloha proběhla, 1 = restic hlásil chybu, 2 = špatné použití.

set -euo pipefail

# --------------------------------------------------------------------------
# Nastavení – klidně si uprav
# --------------------------------------------------------------------------

SOURCES=(
  "$HOME/Documents"
  "$HOME/Dokumenty"
  "$HOME/Desktop"
  "$HOME/Plocha"
  "$HOME/Pictures"
  "$HOME/Obrázky"
  "$HOME/Videos"
  "$HOME/Videa"
  "$HOME/Music"
  "$HOME/Hudba"
  "$HOME/Downloads"
  "$HOME/Stažené"
  "$HOME/Projects"
  "$HOME/projects"
  "$HOME/Projekty"
  "$HOME/dotfiles"
  "$HOME/.thunderbird"
  "$HOME/betterbird-bin"
  "$HOME/Zotero"
  "$HOME/.zotero"
  "$HOME/Knihovna Calibre"
  "$HOME/.ssh"
  "$HOME/.gnupg"
  "$HOME/.gitconfig"
  "$HOME/.npmrc"
  "$HOME/.bashrc"
  "$HOME/.bash_profile"
  "$HOME/.zshrc"
  "$HOME/.profile"
  "$HOME/.config"
)

EXCLUDES=(
  "owncloud"
  "ownCloud"
  "OwnCloud"
  "Nextcloud"
  "nextcloud"
  "Dropbox"
  "Google Drive"
  "GoogleDrive"
  ".cache"
  "Cache"
  "CacheStorage"
  ".local/share/Trash"
  ".Trash"
  "*.tmp"
  "*~"
  ".venv"
  "venv"
  "*venv*"
  "node_modules"
  "__pycache__"
  ".gradle"
  ".m2/repository"
  "target"
  ".steam"
  "Steam"
  "BACKUP"
  "restic-repo"
  # Tip: zálohu uvnitř zálohy vyřaď třeba řádkem   Dokumenty/BACKUP
)

CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ssd-backup"

# --------------------------------------------------------------------------
# Vzhled
# --------------------------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  R=$'\e[0m'; B=$'\e[1m'; D=$'\e[2m'
  CY=$'\e[38;5;44m'; GN=$'\e[38;5;42m'; YL=$'\e[38;5;220m'
  RD=$'\e[38;5;203m'; MG=$'\e[38;5;213m'; GY=$'\e[38;5;245m'
else
  R='' B='' D='' CY='' GN='' YL='' RD='' MG='' GY=''
fi

RULE="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

banner() {
  printf '\n'
  printf '%s\n' "${CY}  ${RULE}${R}"
  printf '%s\n' "${CY}${B}   ◆  SSD BACKUP${R}${CY}  ·  osobní soubory (restic)${R}"
  printf '%s\n' "${GY}   verzovaná, šifrovaná záloha domácích dat na externí disk${R}"
  printf '%s\n' "${MG}${B}   by @ret3030${R}"
  printf '%s\n' "${CY}  ${RULE}${R}"
  printf '\n'
}
step() { printf '\n%s\n' "${CY}${B}▸ $*${R}"; }
info() { printf '  %s\n'  "${GY}$*${R}"; }
ok()   { printf '%s\n'    "${GN}${B}✓${R} $*"; }
warn() { printf '%s\n'    "${YL}${B}!${R} $*"; }
err()  { printf '%s\n'    "${RD}${B}✗${R} $*" >&2; }
kv()   { printf "  ${GY}%-9s${R} %s\n" "$1" "$2"; }

# --------------------------------------------------------------------------
# Argumenty
# --------------------------------------------------------------------------

DEST="${DEST:-}"
WANT_UUID=""
WANT_LABEL=""
DRY_RUN=0
ASSUME_YES=0
DO_UMOUNT=0
UMOUNT_SET=0
DO_POWEROFF=0
SAVE_TARGET=0
FORGET_TARGET=0
SHOW_TARGET=0
LIST_SNAPSHOTS=0
WIPE=0
WIPE_FS=""
PRUNE=0
PRUNE_KEEP=10

while (($#)); do
  case "$1" in
    --dry-run)           DRY_RUN=1 ;;
    -y|--yes)             ASSUME_YES=1 ;;
    --umount|--unmount)  DO_UMOUNT=1; UMOUNT_SET=1 ;;
    --no-umount)          DO_UMOUNT=0; UMOUNT_SET=1 ;;
    --poweroff)           DO_UMOUNT=1; UMOUNT_SET=1; DO_POWEROFF=1 ;;
    --save)               SAVE_TARGET=1 ;;
    --forget)             FORGET_TARGET=1 ;;
    --show-target)        SHOW_TARGET=1 ;;
    --snapshots)           LIST_SNAPSHOTS=1 ;;
    --wipe|--format)      WIPE=1 ;;
    --wipe=*|--format=*)  WIPE=1; WIPE_FS="${1#*=}" ;;
    --prune)               PRUNE=1 ;;
    --prune=*)             PRUNE=1; PRUNE_KEEP="${1#*=}" ;;
    --uuid)                shift || true; WANT_UUID="${1:-}" ;;
    --uuid=*)              WANT_UUID="${1#*=}" ;;
    --label)               shift || true; WANT_LABEL="${1:-}" ;;
    --label=*)             WANT_LABEL="${1#*=}" ;;
    -h|--help)            sed -n '3,29p' "$0" | sed 's/^#\s\{0,1\}//'; exit 0 ;;
    -*)                    echo "Neznámý přepínač: $1" >&2; exit 2 ;;
    *)                     DEST="$1" ;;
  esac
  shift || true
done

case "${WIPE_FS,,}" in ""|ext4|exfat) WIPE_FS="${WIPE_FS,,}" ;;
  *) echo "Neznámý formát pro --wipe: $WIPE_FS (povoleno: ext4, exfat)" >&2; exit 2 ;;
esac

[[ -z "$WANT_UUID"  ]] && WANT_UUID="${DEST_UUID:-}"
[[ -z "$WANT_LABEL" ]] && WANT_LABEL="${DEST_LABEL:-}"

CLI_TARGET_GIVEN=0
[[ -n "$DEST" || -n "$WANT_UUID" || -n "$WANT_LABEL" ]] && CLI_TARGET_GIVEN=1

ask() {  # ask "otázka" "A|N"  -> návrat 0 pro ano; druhý arg = výchozí
  local q="$1" def="${2:-N}" ans hint
  if (( ASSUME_YES )); then return 0; fi
  hint="${D}[a/N]${R}"; [[ "$def" =~ [AaYy] ]] && hint="${D}[A/n]${R}"
  read -r -p "$(printf '%s' "${CY}?${R} $q $hint ")" ans </dev/tty || ans=""
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[AaYy] ]]
}

load_list() {  # load_list NAZEV_POLE soubor
  local -n _arr="$1"; local file="$2" line
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    line="${line/#\~\//$HOME/}"
    _arr+=( "$line" )
  done < "$file"
}
load_list SOURCES  "$CFG_DIR/sources.txt"
load_list EXCLUDES "$CFG_DIR/excludes.txt"

# zapamatovaný disk (jen když nebyl zadaný cíl na příkazové řádce)
if [[ -z "$DEST" && -z "$WANT_UUID" && -z "$WANT_LABEL" && -r "$CFG_DIR/target.conf" ]]; then
  while IFS='=' read -r k v; do
    k="${k//[[:space:]]/}"
    v="${v#\"}"; v="${v%\"}"
    case "$k" in
      UUID)  WANT_UUID="${v//[[:space:]]/}" ;;
      LABEL) WANT_LABEL="$v" ;;
    esac
  done < "$CFG_DIR/target.conf"
fi

banner

# --------------------------------------------------------------------------
# Správa zapamatovaného disku (--forget / --show-target) – bez mountování
# --------------------------------------------------------------------------

if (( FORGET_TARGET )); then
  if [[ -r "$CFG_DIR/target.conf" ]]; then
    rm -f "$CFG_DIR/target.conf"
    ok "Zapamatovaný disk smazán ($CFG_DIR/target.conf)."
  else
    info "Žádný zapamatovaný disk nebyl nastavený – není co zapomenout."
  fi
  exit 0
fi

if (( SHOW_TARGET )); then
  if [[ -n "$WANT_UUID" || -n "$WANT_LABEL" ]]; then
    step "Zapamatovaný disk"
    kv "UUID"   "${WANT_UUID:-—}"
    kv "Štítek" "${WANT_LABEL:-—}"
    kv "Soubor" "$CFG_DIR/target.conf"
  else
    info "Žádný zapamatovaný disk. Ulož ho příště přes --save (nebo --uuid/--label --save)."
  fi
  exit 0
fi

# --------------------------------------------------------------------------
# Prerekvizity
# --------------------------------------------------------------------------

need() { command -v "$1" >/dev/null 2>&1; }

check_prereqs() {
  local miss=()
  need restic || miss+=( restic )
  need awk    || miss+=( awk )
  need lsblk  || miss+=( util-linux )
  if (( ${#miss[@]} )); then
    err "Chybí nástroje: ${miss[*]}"
    if   need apt-get; then info "Nainstaluj: sudo apt install ${miss[*]}"
    elif need dnf;     then info "Nainstaluj: sudo dnf install ${miss[*]}"
    elif need pacman;  then info "Nainstaluj: sudo pacman -S ${miss[*]}"
    elif need zypper;  then info "Nainstaluj: sudo zypper install ${miss[*]}"
    fi
    exit 1
  fi
  need findmnt   || warn "findmnt nenalezen – nepoznám souborový systém cíle."
  need udisksctl || warn "udisksctl nenalezen – připojení disku bude přes 'sudo mount'."

  local v
  v="$(restic version 2>/dev/null | awk '{print $2}')"
  ok "Prerekvizity v pořádku (restic ${v:-?})."
}
check_prereqs

# --------------------------------------------------------------------------
# Heslo repozitáře – vygeneruje se samo při prvním běhu
# --------------------------------------------------------------------------

PASSFILE="$CFG_DIR/restic-password"

ensure_password() {
  [[ -s "$PASSFILE" ]] && return 0
  mkdir -p "$CFG_DIR"
  ( umask 077; head -c 32 /dev/urandom | base64 | tr -d '\n' > "$PASSFILE" )
  chmod 600 "$PASSFILE"
  warn "Vygenerováno nové heslo repozitáře: $PASSFILE"
  warn "BEZ NĚJ SE K ZÁLOZE NEDOSTANEŠ. Udělej si jeho kopii i mimo tenhle počítač (heslenka apod.)."
}

# --------------------------------------------------------------------------
# Identifikace a připojení cílového disku
# --------------------------------------------------------------------------

DEV=""            # /dev/sdX1 cílového disku
MP=""             # jeho mountpoint
WE_MOUNTED=0      # 1 = připojil ho tento skript
MOUNT_VIA=""      # udisks | mount
FSTYPE_HINT=""

SEP=$'\x1f'

lsblk_scan() {
  local line NAME UUID LABEL MOUNTPOINT FSTYPE RM HOTPLUG SIZE TYPE
  while IFS= read -r line; do
    NAME= UUID= LABEL= MOUNTPOINT= FSTYPE= RM= HOTPLUG= SIZE= TYPE=
    eval "$line"
    [[ "$TYPE" == "part" || "$TYPE" == "crypt" || "$TYPE" == "lvm" ]] || continue
    [[ -n "$FSTYPE" ]] || continue
    printf "%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s\n" \
      "$NAME" "$UUID" "$LABEL" "$MOUNTPOINT" "$FSTYPE" "${RM:-0}" "${HOTPLUG:-0}" "$SIZE"
  done < <(lsblk -Ppo NAME,UUID,LABEL,MOUNTPOINT,FSTYPE,RM,HOTPLUG,SIZE,TYPE 2>/dev/null || true)
}

find_target_dev() {
  local n u l mp fs rest
  while IFS="$SEP" read -r n u l mp fs rest; do
    if { [[ -n "$WANT_UUID"  ]] && [[ "$u" == "$WANT_UUID"  ]]; } ||
       { [[ -z "$WANT_UUID"  ]] && [[ -n "$WANT_LABEL" ]] && [[ "$l" == "$WANT_LABEL" ]]; }; then
      DEV="$n"; MP="$mp"; FSTYPE_HINT="$fs"; return 0
    fi
  done < <(lsblk_scan)
  return 1
}

mount_target_dev() {
  [[ -n "$DEV" ]] || return 1
  if [[ -n "$MP" ]]; then
    ok "Disk $DEV je připojený: $MP"
    return 0
  fi

  step "Disk $DEV není připojený – připojuji…"
  if need udisksctl; then
    local out
    if out="$(udisksctl mount -b "$DEV" 2>&1)"; then
      MP="$(printf '%s\n' "$out" | sed -n 's/.* at \(.*[^.]\)\.\?$/\1/p')"
      [[ -z "$MP" ]] && MP="$(lsblk -no MOUNTPOINT "$DEV" 2>/dev/null | head -1)"
      WE_MOUNTED=1; MOUNT_VIA="udisks"
      ok "Připojeno: $MP"
      return 0
    fi
    if printf '%s' "$out" | grep -qi 'already mounted'; then
      MP="$(lsblk -no MOUNTPOINT "$DEV" 2>/dev/null | head -1)"
      [[ -n "$MP" ]] && { ok "Už připojeno: $MP"; return 0; }
    fi
    warn "udisksctl: $out"
  fi

  local sudo="" mp mopts=()
  [[ "$(id -u)" -ne 0 ]] && sudo="sudo"
  mp="/run/media/$(id -un)/${WANT_LABEL:-ssd-backup}"
  case "${FSTYPE_HINT,,}" in
    exfat|vfat|msdos|ntfs|ntfs3)
      mopts=( -o "uid=$(id -u),gid=$(id -g),umask=022" ) ;;
  esac
  $sudo mkdir -p "$mp" 2>/dev/null || { err "Nelze vytvořit přípojný bod $mp"; return 1; }
  if $sudo mount "${mopts[@]}" "$DEV" "$mp"; then
    MP="$mp"; WE_MOUNTED=1; MOUNT_VIA="mount"
    ok "Připojeno: $MP"
    return 0
  fi
  err "Připojení disku $DEV selhalo."
  return 1
}

unmount_target_dev() {
  (( WE_MOUNTED )) || return 0
  [[ -n "$DEV" ]]  || return 0
  sync
  if [[ "$MOUNT_VIA" == "udisks" ]]; then
    if udisksctl unmount -b "$DEV" >/dev/null 2>&1; then
      ok "Disk $DEV odpojen."
      if (( DO_POWEROFF )) && udisksctl power-off -b "$DEV" >/dev/null 2>&1; then
        ok "Disk uspán – můžeš ho vytáhnout."
      fi
    else
      warn "Odpojení selhalo. Odpoj ručně: udisksctl unmount -b $DEV"
    fi
  else
    local sudo=""; [[ "$(id -u)" -ne 0 ]] && sudo="sudo"
    if $sudo umount "$MP"; then ok "Disk $DEV odpojen."
    else warn "Odpojení selhalo. Odpoj ručně: $sudo umount $MP"; fi
  fi
}

save_target_conf() {  # save_target_conf UUID LABEL
  local u="$1" l="$2"
  [[ -n "$u$l" ]] || { warn "Nemám UUID ani štítek – neukládám."; return 0; }
  mkdir -p "$CFG_DIR"
  {
    echo "# SSD Backup – cílový disk (nezávislé na přípojném bodu i počítači)"
    [[ -n "$u" ]] && echo "UUID=$u"
    [[ -n "$l" ]] && echo "LABEL=\"$l\""
  } > "$CFG_DIR/target.conf"
  ok "Uloženo do $CFG_DIR/target.conf – příště stačí:  $(basename "$0") --yes"
}

# --------------------------------------------------------------------------
# Rychlý „chytrý" wipe SSD:  discard/TRIM celého disku → nová GPT → mkfs.
# Volá se jen interaktivně, nikdy s --yes. $1 = /dev uzel (oddíl nebo celý disk).
# --------------------------------------------------------------------------

do_wipe() {
  local part="$1" disk SUDO="" fs newlabel cur_label model size p part1 newuuid ptype
  [[ $EUID -ne 0 ]] && SUDO="sudo"

  if [[ -z "$part" || ( ! -b "$part" ) ]]; then
    err "Pro --wipe musíš určit disk: --uuid, --label, cestu k mountu, nebo /dev/sdX."
    exit 2
  fi
  if (( ASSUME_YES )) || [[ ! -t 0 ]]; then
    err "--wipe se nedá spustit bez dotazů (--yes) ani mimo terminál. Přerušeno."
    exit 2
  fi
  for t in blkdiscard wipefs mkfs.ext4; do
    need "$t" || { err "Chybí nástroj: $t (balík util-linux / e2fsprogs)."; exit 1; }
  done
  need sgdisk || need parted || { err "Chybí sgdisk (gptfdisk) nebo parted."; exit 1; }

  disk="$(lsblk -no PKNAME "$part" 2>/dev/null | head -1)"
  [[ -n "$disk" ]] && disk="/dev/$disk" || disk="$part"

  local rm hp
  rm="$(lsblk -dno RM "$disk" 2>/dev/null | head -1)"
  hp="$(lsblk -dno HOTPLUG "$disk" 2>/dev/null | head -1)"
  if [[ "$rm" != "1" && "$hp" != "1" ]]; then
    err "„$disk\" nevypadá jako výměnný disk (RM=$rm, HOTPLUG=$hp). Wipe interního disku skript nedělá."
    exit 1
  fi
  if lsblk -nrpo NAME,MOUNTPOINT "$disk" 2>/dev/null \
       | awk '$2=="/"||$2=="/boot"||$2=="/boot/efi"||$2=="/home"||$2=="[SWAP]"{f=1} END{exit !f}'; then
    err "Disk $disk nese systémové oddíly (/, /boot, /home nebo swap). WIPE ODMÍTNUT."
    exit 1
  fi

  cur_label="$(lsblk -dno LABEL "$disk" 2>/dev/null | head -1)"
  [[ -z "$cur_label" ]] && cur_label="$(lsblk -nro LABEL "$disk" 2>/dev/null | awk 'NF{print;exit}')"
  model="$(lsblk -dno MODEL "$disk" 2>/dev/null | head -1 | xargs || true)"
  size="$(lsblk -dno SIZE "$disk" 2>/dev/null | head -1)"

  step "⚠  SMAZÁNÍ DISKU"
  kv "Disk"     "$disk"
  kv "Model"    "${model:-?}"
  kv "Velikost" "${size:-?}"
  printf '  %s\n' "${GY}Oddíly, které nenávratně zaniknou:${R}"
  lsblk -no NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$disk" 2>/dev/null | sed 's/^/    /'
  echo
  warn "Tímto NENÁVRATNĚ smažeš VŠECHNA data na $disk."

  local want="${cur_label:-WIPE}" a
  read -r -p "$(printf '  Pro potvrzení napiš přesně „%s": ' "$want")" a </dev/tty || a=""
  [[ "$a" == "$want" ]] || { err "Nesouhlasí („$a“). Přerušeno."; exit 1; }
  ask "Opravdu SMAZAT celý $disk?" "N" || { err "Přerušeno."; exit 1; }

  fs="$WIPE_FS"
  if [[ -z "$fs" ]]; then
    if ask "Formát ext4? (doporučeno; „n\" = exFAT pro sdílení s Windows/macOS)" "A"; then
      fs=ext4
    else
      fs=exfat
      need mkfs.exfat || { err "Chybí mkfs.exfat (balík exfatprogs)."; exit 1; }
    fi
  fi
  newlabel="${cur_label:-SSD_Backup}"
  read -r -p "$(printf '  Štítek nového disku [%s]: ' "$newlabel")" a </dev/tty || a=""
  [[ -n "$a" ]] && newlabel="$a"

  step "Odpojuji oddíly disku…"
  while read -r p; do
    [[ -n "$p" ]] || continue
    udisksctl unmount -b "$p" >/dev/null 2>&1 || $SUDO umount "$p" >/dev/null 2>&1 || true
  done < <(lsblk -nrpo NAME,TYPE "$disk" 2>/dev/null | awk '$2=="part"{print $1}')

  step "Rychlý wipe (discard / TRIM)…"
  if $SUDO blkdiscard -f "$disk"; then
    ok "blkdiscard hotový (SSD buňky uvolněny)."
  else
    warn "blkdiscard neprošel – mažu aspoň metadata a začátek disku."
    $SUDO wipefs -a "$disk" || true
    $SUDO dd if=/dev/zero of="$disk" bs=1M count=32 conv=fsync status=none || true
  fi

  step "Nová tabulka oddílů (GPT)…"
  ptype=8300; [[ "$fs" == exfat ]] && ptype=0700
  if need sgdisk; then
    $SUDO sgdisk --zap-all "$disk" >/dev/null
    $SUDO sgdisk -n "1:0:0" -t "1:$ptype" -c "1:$newlabel" "$disk" >/dev/null
  else
    $SUDO parted -s "$disk" mklabel gpt mkpart primary 0% 100%
  fi
  $SUDO partprobe "$disk" 2>/dev/null || true
  need udevadm && $SUDO udevadm settle 2>/dev/null || true
  sleep 1

  part1="$(lsblk -nrpo NAME,TYPE "$disk" 2>/dev/null | awk '$2=="part"{print $1; exit}')"
  if [[ -z "$part1" ]]; then
    [[ "$disk" =~ [0-9]$ ]] && part1="${disk}p1" || part1="${disk}1"
  fi

  step "Vytvářím $fs na $part1…"
  if [[ "$fs" == ext4 ]]; then
    $SUDO mkfs.ext4 -F -L "$newlabel" -E lazy_itable_init=1,lazy_journal_init=1 "$part1"
  else
    $SUDO mkfs.exfat -L "$newlabel" "$part1" 2>/dev/null || $SUDO mkfs.exfat -n "$newlabel" "$part1"
  fi
  $SUDO partprobe "$disk" 2>/dev/null || true
  need udevadm && $SUDO udevadm settle 2>/dev/null || true

  if [[ "$fs" == ext4 ]]; then
    local tmp; tmp="$(mktemp -d)"
    if $SUDO mount "$part1" "$tmp"; then
      $SUDO chown "$(id -u):$(id -g)" "$tmp"
      $SUDO umount "$tmp"
    fi
    rmdir "$tmp" 2>/dev/null || true
  fi

  newuuid="$(lsblk -no UUID "$part1" 2>/dev/null | head -1)"
  echo
  ok "Hotovo: $disk → $fs, štítek \"$newlabel\", UUID $newuuid"

  WANT_UUID="$newuuid"; WANT_LABEL="$newlabel"; DEST=""
  DEST_DEV_UUID="$newuuid"; DEST_DEV_LABEL="$newlabel"
}

cleanup() {
  local ec=$?
  trap - EXIT INT TERM
  if (( WE_MOUNTED )); then
    if (( DO_UMOUNT )); then
      step "Odpojuji disk"
      unmount_target_dev
    else
      info "Disk nechávám připojený: $MP   (odpojit: udisksctl unmount -b $DEV)"
    fi
  fi
  exit "$ec"
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------------
# Průvodce (interaktivně, když není zadaný žádný cíl)
# --------------------------------------------------------------------------

DEST_DEV_UUID=""
DEST_DEV_LABEL=""

if [[ -z "$DEST" && -z "$WANT_UUID" && -z "$WANT_LABEL" && -t 0 && $ASSUME_YES -eq 0 ]]; then
  step "Kam zálohovat?"
  info "Hledám externí / výměnné disky…"

  mapfile -t ROWS < <(
    while IFS="$SEP" read -r n u l mp fs rm hp size; do
      [[ "$rm" == "1" || "$hp" == "1" ]] || continue
      if [[ -n "$mp" ]]; then
        printf "M${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s (%s)\n" "$mp" "$u" "$l" "$fs" "$size" "${l:-bez štítku}"
      else
        printf "U${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s (%s, %s)\n" "$n" "$u" "$l" "$fs" "$size" "${l:-bez štítku}" "$fs"
      fi
    done < <(lsblk_scan)
  )

  if (( ${#ROWS[@]} )); then
    echo
    i=1
    for row in "${ROWS[@]}"; do
      IFS="$SEP" read -r st path _u _l _fs human <<<"$row"
      tag="připojený"; [[ "$st" == "U" ]] && tag="${YL}nepřipojený${R}"
      printf "   ${YL}${B}%d${R}) ${B}%s${R}  ${GY}%s${R}  [%s]\n" "$i" "$human" "$path" "$tag"
      ((i++))
    done
    printf "   ${YL}${B}0${R}) zadat cestu ručně\n\n"
    read -r -p "$(printf '%s' "${CY}?${R} Vyber číslo cíle: ")" sel </dev/tty || sel=0
  else
    warn "Žádný výměnný disk jsem nenašel."
    sel=0
  fi

  if [[ "$sel" =~ ^[0-9]+$ && "$sel" -ge 1 && "$sel" -le ${#ROWS[@]} ]]; then
    IFS="$SEP" read -r st path ruuid rlabel rfs _h <<<"${ROWS[$((sel-1))]}"
    if [[ "$st" == "M" ]]; then
      DEST="$path"; DEST_DEV_UUID="$ruuid"; DEST_DEV_LABEL="$rlabel"
    else
      WANT_UUID="$ruuid"; WANT_LABEL="$rlabel"
      DEST_DEV_UUID="$ruuid"; DEST_DEV_LABEL="$rlabel"
    fi
  else
    read -r -p "$(printf '%s' "${CY}?${R} Zadej cestu k připojenému SSD: ")" DEST </dev/tty || DEST=""
  fi
fi

if (( ! WIPE )) && [[ -t 0 && $ASSUME_YES -eq 0 && $CLI_TARGET_GIVEN -eq 0 ]]; then
  step "Wipe disku"
  if ask "Než začneme: cílový disk rychle přemazat? (TRIM + nový oddíl – SMAŽE VŠECHNA DATA)" "N"; then
    WIPE=1
  fi
fi

if (( ! WIPE )) && [[ -t 0 && $ASSUME_YES -eq 0 && $CLI_TARGET_GIVEN -eq 0 ]]; then
  step "Zkušební běh"
  if ask "Spustit nejdřív zkušební běh (nic nezapíše)?" "A"; then
    DRY_RUN=1
  fi
fi

# --------------------------------------------------------------------------
# Wipe disku (--wipe / --format)
# --------------------------------------------------------------------------

if (( WIPE )); then
  wipedev=""
  if [[ -n "$WANT_UUID" || -n "$WANT_LABEL" ]]; then
    find_target_dev && wipedev="$DEV" || { err "Disk podle UUID/štítku nenalezen."; exit 1; }
  elif [[ -n "$DEST" && -b "$DEST" ]]; then
    wipedev="$DEST"
  elif [[ -n "$DEST" && -d "$DEST" ]]; then
    wipedev="$(findmnt -no SOURCE -T "$DEST" 2>/dev/null || true)"
  fi
  do_wipe "$wipedev"
  DEV=""; MP=""; WE_MOUNTED=0
  ask "Spustit teď zálohu na čerstvý disk?" "A" || { info "Hotovo. Disk je naformátovaný."; exit 0; }
fi

# --------------------------------------------------------------------------
# Připojení podle UUID / štítku (když nemáme použitelnou cestu)
# --------------------------------------------------------------------------

if [[ ( -z "$DEST" || ! -d "$DEST" ) && ( -n "$WANT_UUID" || -n "$WANT_LABEL" ) ]]; then
  step "Cílový disk"
  kv "Hledám" "${WANT_UUID:+UUID=$WANT_UUID}${WANT_UUID:+  }${WANT_LABEL:+LABEL=$WANT_LABEL}"
  if ! find_target_dev; then
    err "Disk ${WANT_UUID:+UUID=$WANT_UUID }${WANT_LABEL:+LABEL=\"$WANT_LABEL\"} není v systému. Připoj ho a zkus znovu."
    exit 1
  fi
  mount_target_dev || exit 1
  DEST="$MP"
  [[ -z "$DEST_DEV_UUID"  ]] && DEST_DEV_UUID="$(lsblk -no UUID  "$DEV" 2>/dev/null | head -1)"
  [[ -z "$DEST_DEV_LABEL" ]] && DEST_DEV_LABEL="$(lsblk -no LABEL "$DEV" 2>/dev/null | head -1)"
fi

# --------------------------------------------------------------------------
# Kontroly cíle
# --------------------------------------------------------------------------

if [[ -z "$DEST" ]]; then
  err "Neznám cíl. Zadej cestu, --uuid, --label, nebo si disk zapamatuj (--save)."
  exit 2
fi
if [[ ! -d "$DEST" ]]; then
  err "Cíl '$DEST' neexistuje nebo není připojený."
  exit 1
fi
case "$(realpath "$DEST")" in
  "$HOME"|"/"|"") err "Podezřelý cíl '$DEST'. Zadej složku na externím disku."; exit 1 ;;
esac

FSTYPE=""; MNT_SRC=""; MNT_POINT=""
if need findmnt; then
  FSTYPE="$(findmnt -T "$DEST" -no FSTYPE 2>/dev/null || true)"
  MNT_SRC="$(findmnt -T "$DEST" -no SOURCE 2>/dev/null || true)"
  MNT_POINT="$(findmnt -T "$DEST" -no TARGET 2>/dev/null || true)"
fi
if [[ "$FSTYPE" == "fuseblk" && -n "$MNT_SRC" ]]; then
  FSTYPE="$(lsblk -no FSTYPE "$MNT_SRC" 2>/dev/null | head -1 || true)"
fi
[[ -z "$FSTYPE" ]] && FSTYPE="$(stat -f -c %T "$DEST" 2>/dev/null || true)"

FREE_H="$(df -Ph "$DEST" 2>/dev/null | awk 'NR==2{print $4}' || true)"; FREE_H="${FREE_H:-?}"

ROOT_DEV="$(stat -c %d / 2>/dev/null || echo 0)"
DEST_DEV="$(stat -c %d "$DEST" 2>/dev/null || echo 1)"
SUSPECT=""
if [[ -z "$MNT_SRC" || "$MNT_SRC" != /dev/* ]]; then
  SUSPECT="cíl neleží na diskovém oddílu (${MNT_SRC:-neznámé} – nejspíš tmpfs/ramdisk)"
elif [[ "$DEST_DEV" == "$ROOT_DEV" ]]; then
  SUSPECT="cíl leží na systémovém disku – externí SSD nejspíš není připojený"
fi
if [[ -n "$SUSPECT" ]]; then
  err "„$DEST\": $SUSPECT."
  warn "Záloha by šla do prázdné složky, ne na externí disk."
  [[ -n "$MNT_POINT" && "$MNT_POINT" != "$DEST" ]] && info "Cesta spadá pod mount: $MNT_POINT (${FSTYPE:-?})"
  info "Připoj SSD, nebo použij --uuid / --label, ať ho skript připojí sám."
  if (( ASSUME_YES )); then
    err "Běžím bez dotazů (--yes) → přerušeno."
    exit 1
  fi
  ask "Přesto sem zálohovat?" "N" || { err "Přerušeno."; exit 1; }
fi

HOSTDIR="$(hostname)-$(whoami)"
REPO="$DEST/backup/$HOSTDIR/restic-repo"
mkdir -p "$(dirname "$REPO")"

EXISTING=()
for src in "${SOURCES[@]}"; do
  [[ -e "$src" ]] && EXISTING+=( "$src" )
done
if [[ ${#EXISTING[@]} -eq 0 ]]; then
  err "Nenašel jsem žádnou ze zdrojových složek. Uprav SOURCES (nebo $CFG_DIR/sources.txt)."
  exit 1
fi

ensure_password
export RESTIC_REPOSITORY="$REPO"
export RESTIC_PASSWORD_FILE="$PASSFILE"

step "Cíl zálohy"
kv "Repozitář" "$REPO"
kv "Zařízení"  "${MNT_SRC:-?}${DEST_DEV_UUID:+   UUID=$DEST_DEV_UUID}"
kv "Systém"    "${FSTYPE:-?}"
kv "Volno"     "$FREE_H"
kv "Zdrojů"    "${#EXISTING[@]} složek"

# Založit repozitář, pokud ještě neexistuje
if [[ ! -f "$REPO/config" ]]; then
  step "Zakládám nový restic repozitář…"
  mkdir -p "$REPO"
  restic init >/dev/null
  ok "Repozitář založen."
fi

if (( LIST_SNAPSHOTS )); then
  step "Historie záloh"
  restic snapshots
  exit 0
fi

# Zapamatovat disk?
if (( SAVE_TARGET )); then
  save_target_conf "${DEST_DEV_UUID:-$(lsblk -no UUID "$MNT_SRC" 2>/dev/null | head -1)}" \
                   "${DEST_DEV_LABEL:-$(lsblk -no LABEL "$MNT_SRC" 2>/dev/null | head -1)}"
elif [[ -t 0 && $ASSUME_YES -eq 0 && ! -r "$CFG_DIR/target.conf" ]]; then
  if ask "Zapamatovat tenhle disk, ať příště stačí '$(basename "$0") --yes'?" "A"; then
    save_target_conf "${DEST_DEV_UUID:-$(lsblk -no UUID "$MNT_SRC" 2>/dev/null | head -1)}" \
                     "${DEST_DEV_LABEL:-$(lsblk -no LABEL "$MNT_SRC" 2>/dev/null | head -1)}"
  fi
fi

# Odpojit po dokončení?
if (( WE_MOUNTED )) && ! (( UMOUNT_SET )); then
  if (( ASSUME_YES )); then
    DO_UMOUNT=1
  elif ask "Disk připojil skript. Po dokončení ho zase odpojit?" "A"; then
    DO_UMOUNT=1
  fi
fi

# --------------------------------------------------------------------------
# Záloha přes restic
# --------------------------------------------------------------------------

run_backup() {
  local dry="$1" opts=() rc=0

  opts=( backup "${EXISTING[@]}" --tag ssd-backup )
  for pat in "${EXCLUDES[@]}"; do opts+=( --exclude="$pat" ); done
  # --verbose jen pri zkusebnim behu: tam chces videt seznam souboru.
  # Pri ostrem behu zaplavi terminal a odroluje resticuv ukazatel postupu.
  # Pozor, --verbose je u resticu pocitadlo - dvakrat = uroven 2 = jeste vic vypisu.
  (( dry )) && opts+=( --dry-run --verbose )

  local hdr="Záloha"
  (( dry )) && hdr="Záloha  ${YL}(ZKUŠEBNÍ BĚH – nic se nezapíše)${R}"
  step "$hdr"

  set +e
  restic "${opts[@]}"
  rc=$?
  set -e

  echo
  if (( rc == 0 )); then
    ok "Hotovo bez chyb.  $(date '+%Y-%m-%d %H:%M:%S')"
  else
    err "restic skončil s kódem $rc."
  fi
  return "$rc"
}

if (( DRY_RUN )); then
  run_backup 1 || true
  if [[ -t 0 && $ASSUME_YES -eq 0 ]] && ask "Pokračovat teď doopravdy?" "A"; then
    echo
  else
    info "Ukončeno. Nic se nezapsalo."
    exit 0
  fi
fi

rc=0
run_backup 0 || rc=$?

if (( rc == 0 && PRUNE )); then
  step "Prořezávám staré snapshoty (ponechám posledních $PRUNE_KEEP)…"
  restic forget --keep-last "$PRUNE_KEEP" --prune || warn "forget --prune selhalo, snapshoty zůstaly beze změny."
fi

exit "$rc"
