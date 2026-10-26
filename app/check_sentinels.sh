#!/bin/sh
# Check that every sentinel file listed in the sentinel list exists.
# Usage: check_sentinels.sh [LIST_FILE]     (default: /backup/sentinels.conf)
# The list has one absolute sentinel file path per line; blank lines and lines
# starting with # are ignored.
# Exit 0: list is non-empty and every sentinel exists.
# Exit 1: list missing, empty, or any sentinel missing (fail closed). Each problem is
#         logged on stdout. Used by entrypoint.sh and backup_script.sh.

LIST_FILE="${1:-/backup/sentinels.conf}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"; }

if [ ! -f "$LIST_FILE" ]; then
  log "ERROR: sentinel list not found: $LIST_FILE"
  exit 1
fi

COUNT=0
MISSING=0
while IFS= read -r SENTINEL || [ -n "$SENTINEL" ]; do
  SENTINEL=$(printf '%s' "$SENTINEL" | tr -d '\r' | sed 's/^[ \t]*//;s/[ \t]*$//')
  case "$SENTINEL" in
    ""|"#"*) continue ;;
  esac
  COUNT=$((COUNT + 1))
  if [ ! -f "$SENTINEL" ]; then
    log "ERROR: sentinel file missing: $SENTINEL (share not mounted?)"
    MISSING=$((MISSING + 1))
  fi
done < "$LIST_FILE"

if [ "$COUNT" -eq 0 ]; then
  log "ERROR: sentinel list is empty: $LIST_FILE"
  exit 1
fi

[ "$MISSING" -eq 0 ] || exit 1
exit 0
