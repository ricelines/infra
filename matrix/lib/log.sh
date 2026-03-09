# shellcheck shell=sh

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '%s %s\n' "$(timestamp_utc)" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}
