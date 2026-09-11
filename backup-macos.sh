#!/usr/bin/env bash
#
#   SSD BACKUP  ·  by @ret3030
#   Záloha osobních souborů na externí SSD (macOS) přes restic.
#
#   Restic ukládá verzované, deduplikované a šifrované snapshoty – žádné mazání ani
#   přepisování při běžném běhu. Historie zůstává, dokud ji sám neprořízneš (--prune).
#
# Použití:
#   ./backup-macos.sh                          # PRŮVODCE – provede tě krok za krokem
#   ./backup-macos.sh /Volumes/MujSSD
#   DEST=/Volumes/MujSSD ./backup-macos.sh
#   ./backup-macos.sh /Volumes/MujSSD --dry-run     # jen ukázat, co by se zálohovalo
#   ./backup-macos.sh /Volumes/MujSSD --yes         # přeskočit dotazy (launchd/cron)
#   ./backup-macos.sh /Volumes/MujSSD --snapshots   # vypsat historii záloh
#   ./backup-macos.sh /Volumes/MujSSD --prune=10    # po záloze ponechat jen posledních 10 snapshotů
#
# Co se zálohuje: složky v poli SOURCES níže (výchozí = běžné osobní složky v $HOME).
# Co se NEzálohuje: viz EXCLUDES – iCloud Drive, ownCloud, Nextcloud, Dropbox, cache, koš, ~/Library.
#
# Heslo repozitáře: ~/.config/ssd-backup/restic-password (při prvním běhu se vygeneruje samo –
#   BEZ NĚJ SE K ZÁLOZE NEDOSTANEŠ, udělej si z něj i vlastní kopii mimo tenhle disk).
#
# Instalace resticu: brew install restic

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
  "*venv*"
  "node_modules"
  "__pycache__"
  ".gradle"
  ".m2/repository"
  "target"
  "restic-repo"
)

CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ssd-backup"
PASSFILE="$CFG_DIR/restic-password"

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
DRY_RUN=0
ASSUME_YES=0
LIST_SNAPSHOTS=0
PRUNE=0
PRUNE_KEEP=10

for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY_RUN=1 ;;
    -y|--yes)      ASSUME_YES=1 ;;
    --snapshots)   LIST_SNAPSHOTS=1 ;;
    --prune)       PRUNE=1 ;;
    --prune=*)     PRUNE=1; PRUNE_KEEP="${arg#*=}" ;;
    -h|--help)     sed -n '2,22p' "$0"; exit 0 ;;
    -*)            echo "Neznámý přepínač: $arg" >&2; exit 2 ;;
    *)             DEST="$arg" ;;
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
# Kontrola prerekvizit
# --------------------------------------------------------------------------

need() { command -v "$1" >/dev/null 2>&1; }

check_prereqs() {
  local miss=()
  need restic || miss+=( restic )
  need df     || miss+=( df )
  need stat   || miss+=( stat )
  if (( ${#miss[@]} )); then
    err "Chybí nástroje: ${miss[*]}"
    need restic || info "Nainstaluj restic: brew install restic"
    exit 1
  fi
  local v; v="$(restic version 2>/dev/null | awk '{print $2}')"
  ok "Prerekvizity v pořádku (restic ${v:-?})."
}
check_prereqs

ensure_password() {
  [[ -s "$PASSFILE" ]] && return 0
  mkdir -p "$CFG_DIR"
  ( umask 077; head -c 32 /dev/urandom | base64 | tr -d '\n' > "$PASSFILE" )
  chmod 600 "$PASSFILE"
  warn "Vygenerováno nové heslo repozitáře: $PASSFILE"
  warn "BEZ NĚJ SE K ZÁLOZE NEDOSTANEŠ. Udělej si jeho kopii i mimo tenhle počítač."
}

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
    [[ "$(stat -f '%d' "$v" 2>/dev/null || echo y)" == "$ROOT_DEV" ]] && continue
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

  step "Zkušební běh"
  if ask "Spustit nejdřív zkušební běh (nic nezapíše)?" "A"; then
    DRY_RUN=1
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
REPO="$DEST/backup/$HOSTDIR/restic-repo"
mkdir -p "$(dirname "$REPO")"

EXISTING=()
for src in "${SOURCES[@]}"; do
  [[ -e "$src" ]] && EXISTING+=( "$src" )
done
if [[ ${#EXISTING[@]} -eq 0 ]]; then
  err "Nenašel jsem žádnou ze zdrojových složek. Uprav pole SOURCES ve skriptu."
  exit 1
fi

ensure_password
export RESTIC_REPOSITORY="$REPO"
export RESTIC_PASSWORD_FILE="$PASSFILE"

step "Cíl zálohy"
kv "Repozitář" "$REPO"
kv "Zdrojů"    "${#EXISTING[@]} složek"

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
    ok "Hotovo bez chyb.  $(date '+%H:%M:%S')"
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
