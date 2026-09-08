#!/usr/bin/env bash
#
#   SSD BACKUP  ·  by @ret3030
#   Záloha osobních souborů na externí SSD (Linux). Nezávislá na počítači:
#   cíl se určuje podle UUID / štítku disku a když není připojený, skript ho připojí sám.
#
# Použití:
#   ./backup-linux.sh                          # PRŮVODCE – provede tě krok za krokem
#   ./backup-linux.sh /media/$USER/MujSSD      # cíl zadaný cestou
#   ./backup-linux.sh --uuid 1234-ABCD         # cíl podle UUID (připojí se sám)
#   ./backup-linux.sh --label "WD SSD"         # cíl podle štítku (připojí se sám)
#   ./backup-linux.sh --uuid 1234-ABCD --save  # zapamatovat disk do ~/.config/ssd-backup/
#   ./backup-linux.sh --yes                    # bez dotazů; použije zapamatovaný disk (cron)
#
#   Další přepínače:
#   --no-mirror       nemazat na SSD soubory smazané ve zdroji
#   --dry-run         jen ukázat, co by se dělo
#   --umount          po dokončení disk odpojit  (--poweroff = odpojit a uspat)
#   --no-umount       nechat připojený i když ho připojil skript
#   --wipe[=ext4|exfat]  rychlý „chytrý" wipe SSD (TRIM) + nový oddíl + mkfs, pak záloha
#
# Zdroje:  pole SOURCES níže + ~/.config/ssd-backup/sources.txt  (cesta na řádek)
# Výjimky: pole EXCLUDES níže + ~/.config/ssd-backup/excludes.txt
# Návratový kód: 0 = vše přeneseno, 1 = část dat se nepřenesla (viz log), 2 = špatné použití.

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
  "$HOME/.ssh"
  "$HOME/.gnupg"
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
  "node_modules"
  "__pycache__"
  ".gradle"
  ".m2/repository"
  "target"
  ".steam"
  "Steam"
  # Tip: zálohu uvnitř zálohy vyřaď např. řádkem   BACKUP   nebo   Dokumenty/BACKUP
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
  printf '%s\n' "${CY}${B}   ◆  SSD BACKUP${R}${CY}  ·  osobní soubory${R}"
  printf '%s\n' "${GY}   záloha domácích dat na externí disk${R}"
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
MIRROR=1
DRY_RUN=0
ASSUME_YES=0
MIRROR_SET=0
DO_UMOUNT=0
UMOUNT_SET=0
DO_POWEROFF=0
SAVE_TARGET=0
WIPE=0
WIPE_FS=""

while (($#)); do
  case "$1" in
    --no-mirror)        MIRROR=0; MIRROR_SET=1 ;;
    --mirror)           MIRROR=1; MIRROR_SET=1 ;;
    --dry-run)          DRY_RUN=1 ;;
    -y|--yes)           ASSUME_YES=1 ;;
    --umount|--unmount) DO_UMOUNT=1; UMOUNT_SET=1 ;;
    --no-umount)        DO_UMOUNT=0; UMOUNT_SET=1 ;;
    --poweroff)         DO_UMOUNT=1; UMOUNT_SET=1; DO_POWEROFF=1 ;;
    --save)             SAVE_TARGET=1 ;;
    --wipe|--format)    WIPE=1 ;;
    --wipe=*|--format=*) WIPE=1; WIPE_FS="${1#*=}" ;;
    --uuid)             shift || true; WANT_UUID="${1:-}" ;;
    --uuid=*)           WANT_UUID="${1#*=}" ;;
    --label)            shift || true; WANT_LABEL="${1:-}" ;;
    --label=*)          WANT_LABEL="${1#*=}" ;;
    -h|--help)          sed -n '3,24p' "$0" | sed 's/^#\s\{0,1\}//'; exit 0 ;;
    -*)                 echo "Neznámý přepínač: $1" >&2; exit 2 ;;
    *)                  DEST="$1" ;;
  esac
  shift || true
done

case "${WIPE_FS,,}" in ""|ext4|exfat) WIPE_FS="${WIPE_FS,,}" ;;
  *) echo "Neznámý formát pro --wipe: $WIPE_FS (povoleno: ext4, exfat)" >&2; exit 2 ;;
esac

# fallback na proměnné prostředí
[[ -z "$WANT_UUID"  ]] && WANT_UUID="${DEST_UUID:-}"
[[ -z "$WANT_LABEL" ]] && WANT_LABEL="${DEST_LABEL:-}"

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
# Prerekvizity
# --------------------------------------------------------------------------

need() { command -v "$1" >/dev/null 2>&1; }
RSYNC_MAJOR=0

check_prereqs() {
  local miss=()
  need rsync || miss+=( rsync )
  need awk   || miss+=( awk )
  need tee   || miss+=( coreutils )
  need lsblk || miss+=( util-linux )
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
  v="$(rsync --version 2>/dev/null | head -1 || true)"
  RSYNC_MAJOR="$(printf '%s\n' "$v" | sed -n 's/.*version \([0-9]\+\).*/\1/p')"
  RSYNC_MAJOR="${RSYNC_MAJOR:-0}"
  v="$(printf '%s\n' "$v" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
  ok "Prerekvizity v pořádku (rsync ${v:-?})."
}
check_prereqs

# --------------------------------------------------------------------------
# Identifikace a připojení cílového disku
# --------------------------------------------------------------------------

DEV=""            # /dev/sdX1 cílového disku
MP=""             # jeho mountpoint
WE_MOUNTED=0      # 1 = připojil ho tento skript
MOUNT_VIA=""      # udisks | mount
FSTYPE_HINT=""

# Oddělovač polí ve výstupu lsblk_scan – US (0x1f), nevyskytuje se v datech ani ve whitespace.
SEP=$'\x1f'

# Projde bloková zařízení, jeden řádek = NAME|UUID|LABEL|MOUNTPOINT|FSTYPE|RM|HOTPLUG|SIZE  (odděleno $SEP)
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

# Najde /dev uzel podle WANT_UUID nebo WANT_LABEL. Naplní DEV, MP, FSTYPE_HINT.
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

  # fallback přes mount (chce root)
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

  # celý disk nad oddílem
  disk="$(lsblk -no PKNAME "$part" 2>/dev/null | head -1)"
  [[ -n "$disk" ]] && disk="/dev/$disk" || disk="$part"

  # bezpečnostní pojistky
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
    if ask "Formát ext4? (doporučeno pro Linux; „n\" = exFAT pro sdílení s Windows/macOS)" "A"; then
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

RUN_REAL_AFTER=0
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

  if (( ! WIPE )); then
    step "Režim zálohy"
    if [[ $MIRROR_SET -eq 0 ]]; then
      if ask "Zrcadlit? (co smažeš doma, zmizí i na SSD)" "N"; then MIRROR=1; else MIRROR=0; fi
    fi
    if ask "Spustit nejdřív zkušební běh (nic nezapíše)?" "A"; then
      DRY_RUN=1; RUN_REAL_AFTER=1
    fi
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
  DEV=""; MP=""; WE_MOUNTED=0     # čerstvý disk, znovu se identifikuje níž
  ask "Spustit teď zálohu na čerstvý disk?" "A" || { info "Hotovo. Disk je naformátovaný."; exit 0; }
  if [[ $MIRROR_SET -eq 0 ]] && ! ask "Zrcadlit? (co smažeš doma, zmizí i na SSD)" "N"; then MIRROR=0; fi
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

# Souborový systém, zařízení a volné místo cíle
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

case "${FSTYPE,,}" in
  exfat|vfat|msdos|fat|fat32|ntfs|ntfs3|hfs|hfsplus|fuseblk) CROSSFS=1 ;;
  *) CROSSFS=0 ;;
esac

FREE_H="$(df -Ph "$DEST" 2>/dev/null | awk 'NR==2{print $4}' || true)"; FREE_H="${FREE_H:-?}"

# Je cíl opravdu samostatně připojený (externí) disk, nebo jen složka na systémovém
# disku / v ramdisku, protože SSD není připojený?
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
TARGET="$DEST/backup/$HOSTDIR"
mkdir -p "$TARGET"

EXISTING=()
for src in "${SOURCES[@]}"; do
  [[ -e "$src" ]] && EXISTING+=( "$src" )
done
if [[ ${#EXISTING[@]} -eq 0 ]]; then
  err "Nenašel jsem žádnou ze zdrojových složek. Uprav SOURCES (nebo $CFG_DIR/sources.txt)."
  exit 1
fi

step "Cíl zálohy"
kv "Cesta"    "$TARGET"
kv "Zařízení" "${MNT_SRC:-?}${DEST_DEV_UUID:+   UUID=$DEST_DEV_UUID}"
kv "Systém"   "${FSTYPE:-?}"
kv "Volno"    "$FREE_H"
kv "Zdrojů"   "${#EXISTING[@]} složek"

if (( CROSSFS )); then
  warn "Souborový systém cíle je ${FSTYPE} – počítá se s těmito omezeními:"
  info "• neukládá Unixová práva, vlastníky ani rozšířené atributy"
  info "• symlinky se ukládají jako kopie svého cíle (--safe-links), ne jako odkazy"
  info "• nerozlišuje velká/malá písmena – soubory lišící se jen velikostí se přepíšou"
  info "• kvůli chybám „mkstemp\" na exFAT/FAT běží rsync v režimu --inplace"
  info "  Používáš disk jen s Linuxem? Spolehlivější je ext4 (viz README)."
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
# Jeden průchod rsyncem.  $1 = 1 pro zkušební běh.  Návrat 1 = byly chyby.
# --------------------------------------------------------------------------

run_backup() {
  local dry="$1" log opts=() sfx=""
  local -a failed=()
  local n="${#EXISTING[@]}" i=0 rc=0 errlines=0 t dt t_all
  (( dry )) && sfx="-dryrun"
  log="$DEST/backup/backup-$(date +%Y%m%d-%H%M%S)-$HOSTDIR$sfx.log"

  if (( CROSSFS )); then
    opts=( -rt -L --safe-links --no-perms --no-owner --no-group
           --modify-window=1 --inplace --partial )
  else
    opts=( -aAX )
  fi
  opts+=( --human-readable --prune-empty-dirs )
  if (( RSYNC_MAJOR >= 3 )); then opts+=( --info=progress2 ); else opts+=( --progress ); fi
  (( MIRROR )) && opts+=( --delete --delete-excluded )
  (( dry ))    && opts+=( --dry-run )
  for pat in "${EXCLUDES[@]}"; do opts+=( --exclude="$pat" ); done

  local hdr="Záloha"
  (( dry )) && hdr="Záloha  ${YL}(ZKUŠEBNÍ BĚH – nic se nezapíše)${R}"
  step "$hdr"
  kv "Režim" "$([[ $MIRROR -eq 1 ]] && echo 'zrcadlo (maže i na SSD)' || echo 'jen přidává')"
  kv "Log"   "$log"

  t_all="$SECONDS"
  for src in "${EXISTING[@]}"; do
    i=$((i+1))
    local rel destdir
    rel="${src#"$HOME"/}"
    [[ "$rel" == "$src" ]] && rel="$(basename "$src")"
    destdir="$TARGET/$(dirname "$rel")"
    (( dry )) || mkdir -p "$destdir"

    printf '\n  %s%s[%d/%d]%s %s\n' "${CY}▸${R}" "$B" "$i" "$n" "$R" "$src"
    t="$SECONDS"
    set +e
    rsync "${opts[@]}" "$src" "$destdir/" 2>&1 | tee -a "$log"
    rc=${PIPESTATUS[0]}
    set -e
    dt=$(( SECONDS - t ))
    case "$rc" in
      0)  info "hotovo za ${dt}s" ;;
      24) warn "rc=24 – část souborů zmizela během kopírování (neškodné), ${dt}s" ;;
      *)  err "rsync skončil s kódem $rc (${dt}s) – detaily v logu"
          failed+=( "$(basename "$src")  (rc=$rc)" ) ;;
    esac
  done

  errlines="$(grep -c -E '^rsync: |^rsync error:' "$log" 2>/dev/null || true)"
  errlines="${errlines:-0}"

  step "Zapisuji zbytek na disk (sync)…"
  t="$SECONDS"; sync; info "hotovo ($(( SECONDS - t ))s)"

  echo
  if (( ${#failed[@]} == 0 && errlines == 0 )); then
    ok "Hotovo bez chyb za $(( (SECONDS - t_all) / 60 ))m $(( (SECONDS - t_all) % 60 ))s.  $(date '+%Y-%m-%d %H:%M:%S')" \
      | tee -a "$log"
    return 0
  fi
  err "DOKONČENO S CHYBAMI – část dat se NEPŘENESLA." | tee -a "$log" >&2
  if (( ${#failed[@]} )); then
    printf '  %s\n' "Zdroje s chybou:" | tee -a "$log"
    printf '    - %s\n' "${failed[@]}" | tee -a "$log"
  fi
  (( errlines )) && printf '  %s\n' "Chybových řádků v logu: $errlines" | tee -a "$log"
  printf '  %s\n' "Podrobnosti:  grep -nE '^rsync: |^rsync error:' \"$log\"" | tee -a "$log"
  if (( CROSSFS )); then
    printf '  %s\n' "Cíl je ${FSTYPE}. Pokud „mkstemp\" chyby přetrvávají a disk používáš jen s Linuxem," | tee -a "$log"
    printf '  %s\n' "nejspolehlivější je přeformátovat na ext4 (README → „exFAT / FAT / NTFS\")." | tee -a "$log"
  fi
  return 1
}

# --------------------------------------------------------------------------
# Běh
# --------------------------------------------------------------------------

if (( DRY_RUN )); then
  run_backup 1 || true
  if (( RUN_REAL_AFTER )); then
    echo
    if ask "Pokračovat teď doopravdy?" "A"; then
      echo
    else
      info "Ukončeno. Nic se nezapsalo."
      exit 0
    fi
  else
    exit 0
  fi
fi

rc=0
run_backup 0 || rc=$?
exit "$rc"
