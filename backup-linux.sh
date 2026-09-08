#!/usr/bin/env bash
#
#   SSD BACKUP  ·  by @ret3030
#   Jednoduchá záloha osobních souborů na externí SSD (Linux).
#
# Použití:
#   ./backup-linux.sh                          # PRŮVODCE – provede tě krok za krokem
#   ./backup-linux.sh /media/$USER/MujSSD
#   DEST=/mnt/ssd ./backup-linux.sh
#   ./backup-linux.sh /mnt/ssd --no-mirror     # nemazat na SSD soubory smazané ve zdroji
#   ./backup-linux.sh /mnt/ssd --dry-run       # jen ukázat, co by se dělo
#   ./backup-linux.sh /mnt/ssd --yes           # přeskočit dotazy (pro cron apod.)
#
# Co se zálohuje: složky uvedené v poli SOURCES níže (výchozí = běžné osobní složky v $HOME).
# Co se NEzálohuje: viz pole EXCLUDES (ownCloud, Nextcloud, Dropbox, cache, koš, ...).

set -euo pipefail

# --------------------------------------------------------------------------
# Nastavení – klidně si uprav
# --------------------------------------------------------------------------

# Zdrojové složky. Přidej/uber podle sebe. Neexistující se přeskočí.
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

# Vzory, které se NIKDY nezálohují (rsync --exclude). Platí kdekoli ve stromu.
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
)

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
kv()   { printf "  ${GY}%-8s${R} %s\n" "$1" "$2"; }

# --------------------------------------------------------------------------
# Zpracování argumentů
# --------------------------------------------------------------------------

DEST="${DEST:-}"
MIRROR=1
DRY_RUN=0
ASSUME_YES=0
MIRROR_SET=0

for arg in "$@"; do
  case "$arg" in
    --no-mirror) MIRROR=0; MIRROR_SET=1 ;;
    --mirror)    MIRROR=1; MIRROR_SET=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    -y|--yes)    ASSUME_YES=1 ;;
    -h|--help)   sed -n '2,15p' "$0"; exit 0 ;;
    -*)          echo "Neznámý přepínač: $arg" >&2; exit 2 ;;
    *)           DEST="$arg" ;;
  esac
done

ask() {  # ask "otázka" "A|N"  -> návrat 0 pro ano; druhý arg = výchozí
  local q="$1" def="${2:-N}" ans hint
  if (( ASSUME_YES )); then return 0; fi
  hint="${D}[a/N]${R}"; [[ "$def" =~ [AaYy] ]] && hint="${D}[A/n]${R}"
  read -r -p "$(printf '%s' "${CY}?${R} $q $hint ")" ans </dev/tty || ans=""
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[AaYy] ]]
}

banner

# --------------------------------------------------------------------------
# Průvodce (když není zadaný cíl a jsme v terminálu)
# --------------------------------------------------------------------------

if [[ -z "$DEST" && -t 0 && $ASSUME_YES -eq 0 ]]; then
  step "Kam zálohovat?"
  info "Hledám připojené externí disky…"

  mapfile -t CANDS < <(
    lsblk -rno MOUNTPOINT,RM,HOTPLUG,SIZE,LABEL 2>/dev/null \
      | awk '$1!="" && ($2=="1" || $3=="1") {mp=$1; $1=$2=$3=""; sub(/^ +/,""); print mp"\t"$0}'
    for d in /media/"$USER"/* /run/media/"$USER"/* /mnt/*; do
      [[ -d "$d" ]] && printf '%s\t\n' "$d"
    done
  )
  mapfile -t CANDS < <(printf '%s\n' "${CANDS[@]}" | awk -F'\t' 'NF && !seen[$1]++')

  if [[ ${#CANDS[@]} -gt 0 ]]; then
    echo
    i=1
    for c in "${CANDS[@]}"; do
      printf "   ${YL}${B}%d${R}) ${B}%s${R}  ${GY}%s${R}\n" "$i" "${c%%$'\t'*}" "${c#*$'\t'}"
      ((i++))
    done
    printf "   ${YL}${B}0${R}) zadat cestu ručně\n\n"
    read -r -p "$(printf '%s' "${CY}?${R} Vyber číslo cíle: ")" sel </dev/tty || sel=0
  else
    warn "Žádný externí disk jsem nenašel."
    sel=0
  fi

  if [[ "$sel" =~ ^[0-9]+$ && "$sel" -ge 1 && "$sel" -le ${#CANDS[@]} ]]; then
    DEST="${CANDS[$((sel-1))]%%$'\t'*}"
  else
    read -r -p "$(printf '%s' "${CY}?${R} Zadej cestu k připojenému SSD: ")" DEST </dev/tty || DEST=""
  fi

  step "Režim zálohy"
  if [[ $MIRROR_SET -eq 0 ]]; then
    if ask "Zrcadlit? (co smažeš doma, zmizí i na SSD)" "N"; then MIRROR=1; else MIRROR=0; fi
  fi

  if ask "Spustit nejdřív zkušební běh (nic nezapíše)?" "A"; then
    DRY_RUN=1
    RUN_REAL_AFTER=1
  fi
fi

# --------------------------------------------------------------------------
# Kontroly
# --------------------------------------------------------------------------

if [[ -z "$DEST" ]]; then
  err "Neuvedl jsi cílovou složku (mount externího SSD). Např.: $0 /media/$USER/MujSSD"
  exit 2
fi
if [[ ! -d "$DEST" ]]; then
  err "Cíl '$DEST' neexistuje nebo není připojený."
  exit 1
fi
case "$(realpath "$DEST")" in
  "$HOME"|"/"|"") err "Podezřelý cíl '$DEST'. Zadej složku na externím disku."; exit 1 ;;
esac

HOSTDIR="$(hostname)-$(whoami)"
TARGET="$DEST/backup/$HOSTDIR"
mkdir -p "$TARGET"

EXISTING=()
for src in "${SOURCES[@]}"; do
  [[ -e "$src" ]] && EXISTING+=( "$src" )
done
if [[ ${#EXISTING[@]} -eq 0 ]]; then
  err "Nenašel jsem žádnou ze zdrojových složek. Uprav pole SOURCES ve skriptu."
  exit 1
fi

# --------------------------------------------------------------------------
# Jeden průchod rsyncem.  $1 = 1 pro zkušební běh
# --------------------------------------------------------------------------

run_backup() {
  local dry="$1" rc=0 log opts=()
  log="$DEST/backup/backup-$(date +%Y%m%d-%H%M%S)-$HOSTDIR$([[ $dry -eq 1 ]] && echo '-dryrun').log"

  opts=( -aAX --human-readable --prune-empty-dirs )
  if rsync --version 2>/dev/null | head -1 | grep -qE 'version 3\.'; then
    opts+=( --info=progress2 )
  else
    opts+=( --progress )
  fi
  (( MIRROR )) && opts+=( --delete --delete-excluded )
  (( dry ))    && opts+=( --dry-run )
  for pat in "${EXCLUDES[@]}"; do opts+=( --exclude="$pat" ); done

  step "Záloha${dry:+  ${YL}(ZKUŠEBNÍ BĚH – nic se nezapíše)${R}}"
  kv "Zdrojů"  "${#EXISTING[@]} složek"
  kv "Cíl"     "$TARGET"
  kv "Režim"   "$([[ $MIRROR -eq 1 ]] && echo 'zrcadlo (maže i na SSD)' || echo 'jen přidává')"
  kv "Log"     "$log"
  echo

  for src in "${EXISTING[@]}"; do
    local rel destdir
    rel="${src#"$HOME"/}"
    [[ "$rel" == "$src" ]] && rel="$(basename "$src")"
    destdir="$TARGET/$(dirname "$rel")"
    (( dry )) || mkdir -p "$destdir"
    printf '  %s %s\n' "${CY}▸${R}" "$src"
    rsync "${opts[@]}" "$src" "$destdir/" 2>&1 | tee -a "$log" || rc=$?
  done

  sync
  echo
  if [[ $rc -eq 0 ]]; then
    ok "Hotovo bez chyb.  $(date '+%H:%M:%S')" | tee -a "$log"
  else
    warn "Dokončeno, ale rsync hlásil chyby (kód $rc). Zkontroluj log: $log" | tee -a "$log"
  fi
  return $rc
}

if (( DRY_RUN )); then
  run_backup 1 || true
  if [[ "${RUN_REAL_AFTER:-0}" -eq 1 ]]; then
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

run_backup 0
exit $?
