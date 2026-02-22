#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

#######################################
# Globals
#######################################

WORKSPACE=""
INPUT_URL=""
MAX_VIDEOS=""
SLEEP_SECONDS="0"
FORCE="0"
VERBOSE="0"

TOTAL_DISCOVERED=0
COUNT_OK=0
COUNT_SKIP=0

WORKDIR_BASE=""
WORKDIR_RUN=""
META_FILE=""
META_STDERR=""
LIST_FILE=""
LOG_FILE=""

SCRIPT_START_EPOCH="$(date +%s)"

#######################################
# Logging (stdout + file)
#######################################

now_epoch() { date +%s; }
timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
elapsed_total() { echo "$(( $(now_epoch) - SCRIPT_START_EPOCH ))"; }

log_raw() {
  printf '%s | +%ss | %s\n' "$(timestamp)" "$(elapsed_total)" "$1"
}

log() {
  log_raw "$1"
  [ -n "${LOG_FILE:-}" ] && log_raw "$1" >> "$LOG_FILE"
}

vlog() {
  if [ "$VERBOSE" = "1" ]; then
    log "[VERBOSE] $1"
  fi
}

err() {
  msg="ERROR | $1"
  log_raw "$msg" >&2
  [ -n "${LOG_FILE:-}" ] && log_raw "$msg" >> "$LOG_FILE"
}

die() {
  err "$1"
  exit 1
}

#######################################
# Usage
#######################################

usage() {
  cat <<EOF
Usage:
  yt_process --workspace "<WORKSPACE_PATH>" --url "<YOUTUBE_CHANNEL_OR_VIDEO_URL>"

Optional:
  --max N
  --sleep-seconds S
  --force
  --verbose
EOF
}

#######################################
# Dependencies
#######################################

check_deps() {
  log "Checking dependencies..."
  command -v yt-dlp >/dev/null 2>&1 || die "Missing dependency: yt-dlp"
  command -v curl >/dev/null 2>&1 || die "Missing dependency: curl"
  command -v jq >/dev/null 2>&1 || die "Missing dependency: jq"
  log "Dependencies OK"
}

#######################################
# Args
#######################################

parse_args() {
  [ "$#" -gt 0 ] || { usage; exit 2; }

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --workspace) WORKSPACE="$2"; shift 2 ;;
      --url) INPUT_URL="$2"; shift 2 ;;
      --max) MAX_VIDEOS="$2"; shift 2 ;;
      --sleep-seconds) SLEEP_SECONDS="$2"; shift 2 ;;
      --force) FORCE="1"; shift ;;
      --verbose) VERBOSE="1"; shift ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  [ -n "$WORKSPACE" ] || die "Missing --workspace"
  [ -n "$INPUT_URL" ] || die "Missing --url"
}

#######################################
# Workdir
#######################################

setup_workdir() {
  WORKDIR_BASE="${WORKSPACE}/.work/yt_process"
  mkdir -p "$WORKDIR_BASE"

  run_id="$(date +%Y%m%d-%H%M%S)-pid$$"
  WORKDIR_RUN="${WORKDIR_BASE}/${run_id}"
  mkdir -p "$WORKDIR_RUN"

  LOG_FILE="${WORKDIR_RUN}/run.log"
  META_FILE="${WORKDIR_RUN}/input_meta.json"
  META_STDERR="${WORKDIR_RUN}/yt-dlp.meta.stderr"
  LIST_FILE="${WORKDIR_RUN}/videos.tsv"

  log "Workdir: $WORKDIR_RUN"
  log "Log file: $LOG_FILE"
}

#######################################
# Sanitization
#######################################

sanitize() {
  s="$1"
  s=$(printf '%s' "$s" | tr '\000-\037\177' '_')
  s=$(printf '%s' "$s" | sed -E 's/[\/\\:\*\?"<>|]/_/g')
  s=$(printf '%s' "$s" | sed -E 's/[[:space:]]+/_/g')
  s=$(printf '%s' "$s" | sed -E 's/_+/_/g')
  s=$(printf '%s' "$s" | sed -E 's/^[._ ]+//; s/[._ ]+$//')
  [ -n "$s" ] || s="unknown"
  printf '%s' "$s"
}

truncate_bytes() { printf '%s' "$1" | head -c 110; }

#######################################
# Input Detection (ignore yt-dlp errors)
#######################################

INPUT_TYPE=""

detect_input_type() {
  log "Detecting input type..."

  set +e
  yt-dlp --flat-playlist --skip-download --no-update -J -- "$INPUT_URL" >"$META_FILE" 2>"$META_STDERR"
  rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    log "yt-dlp returned non-zero ($rc) — continuing"
  fi

  if ! jq empty <"$META_FILE" >/dev/null 2>&1; then
    log "Metadata invalid — assuming single video"
    INPUT_TYPE="video"
    return
  fi

  if jq -e '.entries? | type=="array"' <"$META_FILE" >/dev/null 2>&1; then
    INPUT_TYPE="playlist"
  else
    INPUT_TYPE="video"
  fi

  log "Detected type: $INPUT_TYPE"
}

#######################################
# Channel
#######################################

derive_channel_name() {
  local title=""
  if [ -s "$META_FILE" ] && jq empty <"$META_FILE" >/dev/null 2>&1; then
    title="$(jq -r '.title // empty' <"$META_FILE")"
  fi
  sanitize "${title:-channel}"
}

#######################################
# Listing
#######################################

list_videos_to_file() {
  log "Listing videos..."

  if [ "$INPUT_TYPE" = "video" ]; then
    yt-dlp --skip-download --no-update \
      --print "%(id)s" --print "%(title)s" -- "$INPUT_URL" >"$LIST_FILE"
  else
    yt-dlp --flat-playlist --skip-download --no-update \
      --print "%(id)s" --print "%(title)s" -- "$INPUT_URL" >"$LIST_FILE"
  fi

  TOTAL_DISCOVERED="$(grep -c '.*' "$LIST_FILE" || true)"
  # Each video has 2 lines (id and title)
  TOTAL_DISCOVERED=$((TOTAL_DISCOVERED / 2))
  log "Discovered: $TOTAL_DISCOVERED videos"
}

#######################################
# Process Video (STOP on ERROR)
#######################################

process_video() {
  local channel="$1"
  local vid="$2"
  local title="$3"
  local video_start_epoch
  local safe_title
  local folder
  local dir
  local out
  local url_file
  local url
  local tmp_body
  local http_code
  local video_duration

  video_start_epoch="$(date +%s)"

  vid="$(printf '%s' "$vid" | tr -cd 'A-Za-z0-9_-')"
  [ -n "$vid" ] || die "Empty videoId"

  safe_title="$(sanitize "$(truncate_bytes "$title")")"
  folder="${vid}-${safe_title}"
  dir="${WORKSPACE}/${channel}/${folder}"
  out="${dir}/response.json"
  url_file="${dir}/video.url"

  mkdir -p "$dir"
  printf 'https://youtu.be/%s\n' "$vid" > "$url_file"

  if [ "$FORCE" != "1" ] && [ -s "$out" ]; then
    log "SKIP  $vid"
    COUNT_SKIP=$((COUNT_SKIP+1))
    return
  fi

  url="http://localhost:8080/url=https://youtu.be/${vid}"
  tmp_body="${WORKDIR_RUN}/curl.${vid}.tmp"

  http_code="$(curl -sS -o "$tmp_body" -w '%{http_code}' -- "$url")" \
    || die "curl failed for $vid"

  video_duration="$(( $(date +%s) - video_start_epoch ))"

  if ! echo "$http_code" | grep -Eq '^2[0-9][0-9]$'; then
    die "HTTP $http_code for video $vid"
  fi

  mv -f "$tmp_body" "$out"
  log "OK    $vid (duration ${video_duration}s)"
  COUNT_OK=$((COUNT_OK+1))

  [ "$SLEEP_SECONDS" != "0" ] && sleep "$SLEEP_SECONDS"
}

#######################################
# Main
#######################################

main() {
  parse_args "$@"
  mkdir -p "$WORKSPACE"
  setup_workdir
  check_deps

  detect_input_type
  channel="$(derive_channel_name)"
  mkdir -p "${WORKSPACE}/${channel}"

  list_videos_to_file

  processed_target="$TOTAL_DISCOVERED"
  [ -n "$MAX_VIDEOS" ] && [ "$MAX_VIDEOS" -lt "$processed_target" ] && processed_target="$MAX_VIDEOS"

  i=0
  while read -r vid; do
    read -r title || title=""
    [ -n "$vid" ] || continue
    [ -n "$MAX_VIDEOS" ] && [ "$i" -ge "$MAX_VIDEOS" ] && break

    log "Progress: $((i+1))/${processed_target}"
    process_video "$channel" "$vid" "${title:-unknown}"
    i=$((i+1))
  done <"$LIST_FILE"

  total_runtime="$(( $(date +%s) - SCRIPT_START_EPOCH ))"
  log "Summary: OK=$COUNT_OK SKIP=$COUNT_SKIP"
  log "Total runtime: ${total_runtime}s"
  log "Workdir: $WORKDIR_RUN"
}

main "$@"
