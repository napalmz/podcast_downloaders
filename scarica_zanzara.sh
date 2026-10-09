#!/usr/bin/env bash
# Scarica gli MP3 de "La Zanzara" dal giorno successivo all'ultimo già presente
# (o da START_DATE se non ne trova), usando prima il feed RSS ufficiale.
# Salta sabati,domeniche e festività mobili (es. Pasquetta) se non usa il feed RSS.
# Requisiti: bash + GNU date + wget

set -euo pipefail

# === Configurazione ===
BASE_URL="https://podcast-radio24.ilsole24ore.com/radio24_audio"
FEED_URL="https://www.radio24.ilsole24ore.com/podcast/lazanzara.xml"
SHOW_SLUG="lazanzara"
#START_DATE="2016-01-05" # Data originale di inizio dei podcast sul sito di radio24
START_DATE="2026-01-01" # Data iniziale usata se non trova episodi già scaricati
OUT_DIR="/mnt/user/Multimedia/Podcasts/La Zanzara" # Impostare path corretto
WAIT_SECONDS=1
USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome Safari"

# === Modalità di esecuzione ===
DRY_RUN=0   # 1 = non scarica/non cancella/non sposta, mostra solo cosa farebbe
DEBUG=0     # 1 = output più verboso + trace

usage() {
  cat <<'EOF'
Uso: scarica_zanzara.sh [--dry-run|-n] [--debug|-d]
  --dry-run, -n   Mostra le azioni senza scaricare/cancellare/spostare file
  --debug,   -d   Modalità verbosa (bash trace + wget non silenzioso)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    -d|--debug)
      DEBUG=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Argomento non riconosciuto: $1" >&2
      usage
      exit 2
      ;;
  esac
done

# Trace bash in debug
if [[ "$DEBUG" -eq 1 ]]; then
  set -x
fi

log() {
  # log sempre su stdout
  echo "$@"
}

# === Colori log ===
if [[ -t 1 ]]; then
  CLR_RESET="\033[0m"
  CLR_RED="\033[31m"
  CLR_GREEN="\033[32m"
  CLR_YELLOW="\033[33m"
  CLR_BLUE="\033[36m"
  CLR_PURPLE="\033[35m"
else
  CLR_RESET=""
  CLR_RED=""
  CLR_GREEN=""
  CLR_YELLOW=""
  CLR_BLUE=""
  CLR_PURPLE=""
fi

log_info()   { echo -e "${CLR_BLUE}[INFO]${CLR_RESET} $*"; }
log_ok()     { echo -e "${CLR_GREEN}[OK]${CLR_RESET} $*"; }
log_warn()   { echo -e "${CLR_YELLOW}[WARN]${CLR_RESET} $*"; }
log_error()  { echo -e "${CLR_RED}[ERR]${CLR_RESET} $*"; }
log_dry()    { echo -e "${CLR_PURPLE}[DRY]${CLR_RESET} $*"; }

run_cmd() {
  # Wrapper per supportare dry-run
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_dry "$*"
    return 0
  fi
  "$@"
}

# In debug non usiamo --quiet per vedere eventuali redirect/errori HTTP
WGET_QUIET_OPT="--quiet"
if [[ "$DEBUG" -eq 1 ]]; then
  WGET_QUIET_OPT=""
fi

# Festività a data mobile (Italia): al momento gestiamo Pasquetta (Lunedì dell'Angelo)
# Nota: Pasqua cade sempre di domenica, quindi è già saltata dal check weekend.
# Se vuoi aggiungere altre date mobili, vedi la funzione `is_movable_holiday`.

# Cache per anno -> date calcolate (evita ricalcoli nel loop)
# Richiede bash 4+ (su Linux ok). Su macOS con bash 3 non funziona.
# Lo script richiede già GNU date, quindi tipicamente gira su Linux.

declare -A EASTER_CACHE=()
declare -A EASTER_MONDAY_CACHE=()

# Calcola la data di Pasqua (calendario gregoriano) nel formato YYYY-MM-DD
# Algoritmo: Anonymous Gregorian algorithm
calc_easter() {
  local y=$1
  local a=$(( y % 19 ))
  local b=$(( y / 100 ))
  local c=$(( y % 100 ))
  local d=$(( b / 4 ))
  local e=$(( b % 4 ))
  local f=$(( (b + 8) / 25 ))
  local g=$(( (b - f + 1) / 3 ))
  local h=$(( (19*a + b - d - g + 15) % 30 ))
  local i=$(( c / 4 ))
  local k=$(( c % 4 ))
  local l=$(( (32 + 2*e + 2*i - h - k) % 7 ))
  local m=$(( (a + 11*h + 22*l) / 451 ))
  local month=$(( (h + l - 7*m + 114) / 31 ))
  local day=$(( ((h + l - 7*m + 114) % 31) + 1 ))
  printf "%04d-%02d-%02d" "$y" "$month" "$day"
}

# Ritorna 0 (true) se la data YYYY-MM-DD è una festività mobile da saltare
is_movable_holiday() {
  local yyyymmdd=$1
  local yyyy=${yyyymmdd:0:4}

  # Pasqua (domenica) è già coperta dal weekend, ma calcoliamola per Pasquetta
  if [[ -z "${EASTER_CACHE[$yyyy]:-}" ]]; then
    EASTER_CACHE[$yyyy]=$(calc_easter "$yyyy")
    EASTER_MONDAY_CACHE[$yyyy]=$(date -d "${EASTER_CACHE[$yyyy]} +1 day" +%F)
  fi

  # Pasquetta (Lunedì dell'Angelo)
  if [[ "$yyyymmdd" == "${EASTER_MONDAY_CACHE[$yyyy]}" ]]; then
    return 0
  fi

  return 1
}

# === Controlli preliminari ===
command -v wget >/dev/null || { echo "Errore: wget non trovato."; exit 1; }
run_cmd mkdir -p "$OUT_DIR"

# --- Weekend o festivo? ---
is_skip_day() {
  local dow=$1
  local yyyymmdd=$2

  # Weekend (GNU date: 1=lun ... 7=dom)
  if (( dow >= 6 )); then
    return 0
  fi

  # Festivi a data fissa (formato: MM-DD)
  # 01-01 Capodanno
  # 01-06 Epifania
  # 04-25 Festa della Liberazione
  # 05-01 Festa dei Lavoratori
  # 06-02 Festa della Repubblica
  # 08-15 Ferragosto
  # 11-01 Ognissanti
  # 12-08 Immacolata Concezione
  # 12-25 Natale
  # 12-26 Santo Stefano
  local md="${yyyymmdd:5:2}-${yyyymmdd:8:2}"

  case "$md" in
    01-01|01-06|04-25|05-01|06-02|08-15|11-01|12-08|12-25|12-26)
      return 0
      ;;
  esac

  # Festività a data mobile (es. Pasquetta)
  if is_movable_holiday "$yyyymmdd"; then
    return 0
  fi

  return 1
}

# Riprende dal giorno successivo all'ultimo episodio scaricato; se non ne trova,
# usa START_DATE come data iniziale.
last_downloaded_date=""
if [[ -d "$OUT_DIR" ]]; then
  while IFS= read -r -d '' downloaded_file; do
    [[ -s "$downloaded_file" ]] || continue
    file_name="${downloaded_file##*/}"
    downloaded_date="${file_name#La Zanzara - }"
    downloaded_date="${downloaded_date%.mp3}"

    if [[ "$downloaded_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
      && [[ "$(date -d "$downloaded_date" +%F 2>/dev/null || true)" == "$downloaded_date" ]] \
      && [[ -z "$last_downloaded_date" || "$downloaded_date" > "$last_downloaded_date" ]]; then
      last_downloaded_date="$downloaded_date"
    fi
  done < <(find "$OUT_DIR" -type f -name 'La Zanzara - ????-??-??.mp3' -print0)
fi

if [[ -n "$last_downloaded_date" ]]; then
  START_DATE="$(date -d "$last_downloaded_date +1 day" +%F)"
  log_info "Ultimo episodio già scaricato: $last_downloaded_date; riparto da $START_DATE."
else
  log_info "Nessun episodio già scaricato trovato; uso la data iniziale $START_DATE."
fi

# Riprende dal feed RSS per le puntate recenti; prima del limite dell'indice
# mantiene la ricerca giornaliera, così non si perdono puntate più vecchie.
download_episode() {
  local yyyymmdd=$1
  local url=$2
  local yyyy="${yyyymmdd:0:4}"
  local year_dir="${OUT_DIR}/${yyyy}"
  local file_path="${year_dir}/La Zanzara - ${yyyymmdd}.mp3"
  local tmp_path="${file_path}.tmp"
  local exit_code=0

  run_cmd mkdir -p "$year_dir"

  if [ -f "$file_path" ] && [ ! -s "$file_path" ]; then
    log_warn "Presente ma vuoto (0 byte): La Zanzara - ${yyyymmdd}.mp3 — riscarico."
    run_cmd rm -f "$file_path"
  fi

  if [ -s "$file_path" ]; then
    log_ok "Già presente: La Zanzara - ${yyyymmdd}.mp3 — salto. ($file_path)"
    return
  fi

  log_info "Provo: La Zanzara - ${yyyymmdd}.mp3 - $url"
  run_cmd rm -f "$tmp_path"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_dry "wget $url -> $tmp_path"
    log_dry "(poi validerei size>0 e farei mv su $file_path)"
    return
  fi

  # shellcheck disable=SC2086
  wget \
    ${WGET_QUIET_OPT} \
    --tries=3 \
    --timeout=30 \
    --wait="$WAIT_SECONDS" \
    --random-wait \
    --user-agent="$USER_AGENT" \
    --output-document="$tmp_path" \
    "$url" || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    run_cmd rm -f "$tmp_path"
    if [ "$exit_code" -eq 8 ]; then
      log_warn "Assente (wget exit 8): La Zanzara - ${yyyymmdd}.mp3"
    else
      log_error "Errore ($exit_code) su La Zanzara - ${yyyymmdd}.mp3 — continuo."
    fi
  elif [ ! -s "$tmp_path" ]; then
    log_warn "Assente (scaricato 0 byte): La Zanzara - ${yyyymmdd}.mp3"
    run_cmd rm -f "$tmp_path"
  else
    run_cmd mv -f "$tmp_path" "$file_path"
    log_ok "OK: La Zanzara - ${yyyymmdd}.mp3"
  fi
}

feed_tmp="$(mktemp)"
index_raw="$(mktemp)"
index_tsv="$(mktemp)"
index_sorted="$(mktemp)"
trap 'rm -f "$feed_tmp" "$index_raw" "$index_tsv" "$index_sorted"' EXIT

log_info "Scarico l'indice RSS: $FEED_URL"
# shellcheck disable=SC2086
if ! wget \
  ${WGET_QUIET_OPT} \
  --tries=3 \
  --timeout=30 \
  --user-agent="$USER_AGENT" \
  --output-document="$feed_tmp" \
  "$FEED_URL"; then
  log_error "Impossibile scaricare l'indice RSS."
  exit 1
fi

if ! grep -q '<rss' "$feed_tmp" || ! grep -q '</rss>' "$feed_tmp"; then
  log_error "La risposta del feed RSS non è un documento RSS valido."
  exit 1
fi

if ! awk '
  /<item>/ { in_item=1; pub_date=""; media_url="" }
  in_item && /<pubDate>/ {
    value=$0
    sub(/^.*<pubDate>/, "", value)
    sub(/<\/pubDate>.*/, "", value)
    pub_date=value
  }
  in_item && /<enclosure/ {
    value=$0
    sub(/^.*url="/, "", value)
    sub(/".*$/, "", value)
    media_url=value
  }
  in_item && /<\/item>/ {
    if (pub_date != "" && media_url != "") print pub_date "\t" media_url
    in_item=0
  }
' "$feed_tmp" > "$index_raw"; then
  log_error "Impossibile leggere le puntate dall'indice RSS."
  exit 1
fi

if [[ ! -s "$index_raw" ]]; then
  log_error "L'indice RSS non contiene puntate leggibili."
  exit 1
fi

feed_item_count="$(grep -c '<item>' "$feed_tmp" || true)"
parsed_item_count="$(wc -l < "$index_raw")"
if [[ "$feed_item_count" -eq 0 || "$parsed_item_count" -ne "$feed_item_count" ]]; then
  log_error "Indice RSS incompleto: lette $parsed_item_count puntate su $feed_item_count."
  exit 1
fi

while IFS=$'\t' read -r published_at media_url; do
  if ! published_date="$(date -d "$published_at" +%F)"; then
    log_error "Data non valida nell'indice RSS: $published_at"
    exit 1
  fi

  media_url="${media_url//&amp;/&}"
  if [[ "$media_url" != https://podcast-radio24.ilsole24ore.com/radio24_audio/* ]]; then
    log_error "URL MP3 non valido nell'indice RSS: $media_url"
    exit 1
  fi
  printf '%s\t%s\n' "$published_date" "$media_url" >> "$index_tsv"
done < "$index_raw"

if ! sort -t $'\t' -k1,1 "$index_tsv" > "$index_sorted"; then
  log_error "Impossibile ordinare le puntate dell'indice RSS."
  exit 1
fi

oldest_index_date="$(head -n 1 "$index_sorted" | cut -f 1)"
today="$(date +%F)"
log_info "Indice RSS disponibile dal $oldest_index_date; scarico da $START_DATE a oggi in $OUT_DIR."

if [[ "$START_DATE" < "$oldest_index_date" ]]; then
  fallback_end="$(date -d "$oldest_index_date -1 day" +%F)"
  ts="$(date -d "$START_DATE" +%s)"
  fallback_end_epoch="$(date -d "$fallback_end" +%s)"

  while [[ "$ts" -le "$fallback_end_epoch" ]]; do
    yyyy="$(date -d "@$ts" +%Y)"
    yymmdd="$(date -d "@$ts" +%y%m%d)"
    yyyymmdd="$(date -d "@$ts" +%F)"
    dow="$(date -d "@$ts" +%u)"  # 1..7 (lun..dom)

    if is_skip_day "$dow" "$yyyymmdd"; then
      log_info "Salto (no programma): $yyyymmdd"
    else
      url="${BASE_URL}/${yyyy}/${yymmdd}-${SHOW_SLUG}.mp3"
      download_episode "$yyyymmdd" "$url"
    fi
    ts=$(( ts + 86400 ))
  done
fi

while IFS=$'\t' read -r yyyymmdd url; do
  if [[ "$yyyymmdd" < "$START_DATE" || "$yyyymmdd" > "$today" ]]; then
    continue
  fi
  download_episode "$yyyymmdd" "$url"
done < "$index_sorted"

log_ok "Fatto"
