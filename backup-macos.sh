#!/usr/bin/env bash
#
#   SSD BACKUP  ·  by @ret3030
#   Jednoduchá záloha osobních souborů na externí SSD (macOS).
#
# Použití:
#   ./backup-macos.sh                          # PRŮVODCE – provede tě krok za krokem
#   ./backup-macos.sh /Volumes/MujSSD
#   DEST=/Volumes/MujSSD ./backup-macos.sh
#   ./backup-macos.sh /Volumes/MujSSD --no-mirror   # nemazat na SSD smazané soubory
#   ./backup-macos.sh /Volumes/MujSSD --dry-run     # jen ukázat, co by se dělo
#   ./backup-macos.sh /Volumes/MujSSD --yes         # přeskočit dotazy (launchd/cron)
#
# Co se zálohuje: složky v poli SOURCES níže (výchozí = běžné osobní složky v $HOME).
# Co se NEzálohuje: viz EXCLUDES – iCloud Drive, ownCloud, Nextcloud, Dropbox, cache, koš, ~/Library.
#
# Tip: pro rychlejší a úplnější zálohu (ACL, progress) doporučuju `brew install rsync`.

set -euo pipefail

# --------------------------------------------------------------------------
# Nastavení – klidně si uprav
# --------------------------------------------------------------------------

SOURCES=(
  "$HOME/Documents"
  "$HOME/Desktop"
  "$HOME/Pictures"
  "$HOME/Movies"
  "$HOME/Music"
  "$HOME/Downloads"
  "$HOME/Public"
  "$HOME/Projects"
  "$HOME/.ssh"
  "$HOME/.gnupg"
  "$HOME/.zshrc"
  "$HOME/.bashrc"
  "$HOME/.bash_profile"
  "$HOME/.config"
)

# Názvy/vzory, které se NIKDY nezálohují. Platí kdekoli ve stromu.
EXCLUDES=(
  "com~apple~CloudDocs"          # iCloud Drive
  "Library/Mobile Documents"    # iCloud kontejnery
  "owncloud"
  "ownCloud"
  "OwnCloud"
  "Nextcloud"
  "nextcloud"
  "Dropbox"
  "Google Drive"
  "GoogleDrive"
  ".cache"
  "Caches"
  "Library/Caches"
  ".Trash"
  ".DS_Store"
  "*.tmp"
  "*~"
  ".venv"
  "venv"
  "node_modules"
  "__pycache__"
  ".gradle"
  ".m2/repository"
  "target"
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
# Argumenty
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
    -h|--help)   sed -n '2,18p' "$0"; exit 0 ;;
    -*)          echo "Neznámý přepínač: $arg" >&2; exit 2 ;;
    *)           DEST="$arg" ;;
  esac
done

ask() {
  local q="$1" def="${2:-N}" ans hint
  if (( ASSUME_YES )); then return 0; fi
  hint="${D}[a/N]${R}"; [[ "$def" =~ [AaYy] ]] && hint="${D}[A/n]${R}"
  read -r -p "$(printf '%s' "${CY}?${R} $q $hint ")" ans </dev/tty || ans=""
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[AaYy] ]]
}

banner

# --------------------------------------------------------------------------
# Průvodce
# --------------------------------------------------------------------------

if [[ -z "$DEST" && -t 0 && $ASSUME_YES -eq 0 ]]; then
  step "Kam zálohovat?"
  info "Hledám připojené svazky v /Volumes…"

  ROOT_DEV="$(stat -f '%d' / 2>/dev/null || echo x)"
  CANDS=()
  for v in /Volumes/*; do
    [[ -d "$v" ]] || continue
    [[ "$(stat -f '%d' "$v" 2>/dev/null || echo y)" == "$ROOT_DEV" ]] && continue   # přeskoč systémový disk
    size="$(df -h "$v" 2>/dev/null | awk 'NR==2{print $4" volno / "$2}')"
    CANDS+=( "$v"$'\t'"$size" )
  done

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
    warn "Žádný externí svazek jsem nenašel."
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
  err "Neuvedl jsi cíl. Např.: $0 /Volumes/MujSSD"
  exit 2
fi
if [[ ! -d "$DEST" ]]; then
  err "Cíl '$DEST' neexistuje nebo není připojený."
  exit 1
fi
case "$(cd "$DEST" && pwd -P)" in
  "$HOME"|"/"|"") err "Podezřelý cíl '$DEST'. Zadej externí disk."; exit 1 ;;
esac

HOSTDIR="$(scutil --get LocalHostName 2>/dev/null || hostname -s)-$(whoami)"
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

  # -a bez -X pro kompatibilitu se systémovým rsyncem; -E zachová resource forky/xattr
  opts=( -a -E --human-readable --prune-empty-dirs )
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
