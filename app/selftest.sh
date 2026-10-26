#!/bin/bash
# Self-test of a configured, running container. Run it on the host after deployment:
#   docker exec <container> /backup/selftest.sh [--sentinels FILE] [JOBFILE ...]
# Defaults: sentinels /backup/sentinels.conf, job files /backup/backup_folders.conf and
# /backup/sync_folders.conf.
#
# Checks (one line each, "ok:" or "FAIL:"):
#   - every sentinel listed exists (check_sentinels.sh)
#   - cron is running
#   - every job line is a known operation with the expected fields, and every source
#     directory exists
#   - every retention file used by a PURGE line exists and loads (YAML, the same settings
#     model and PolicyBuilder as apply_retention_policy.py)
#   - every distinct destination is writable: a file .selftest_<timestamp>_<pid> is created
#     and deleted in the destination, or, if it does not exist yet, in its nearest existing
#     ancestor. The destination itself is never created, and nothing is written outside the
#     mount roots of the sentinels (a destination outside them is reported as a problem).
# Read-only apart from that temporary file. Exit 0 when all pass, 1 otherwise.

HERE="$(cd "$(dirname "$0")" && pwd)"
SENTINELS=/backup/sentinels.conf
JOBFILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --sentinels) [ $# -ge 2 ] || { echo "--sentinels needs a file" >&2; exit 2; }; SENTINELS="$2"; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) JOBFILES+=("$1") ;;
  esac
  shift
done
[ ${#JOBFILES[@]} -gt 0 ] || JOBFILES=(/backup/backup_folders.conf /backup/sync_folders.conf)

PROBLEMS=0
ok()  { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; PROBLEMS=$((PROBLEMS + 1)); }

# ---- sentinels ---------------------------------------------------------------------
ROOTS=()
if out="$("$HERE/check_sentinels.sh" "$SENTINELS" 2>&1)"; then
  ok "sentinels present ($SENTINELS)"
else
  bad "sentinels ($SENTINELS):"
  sed 's/^/        /' <<<"$out"
fi
if [ -f "$SENTINELS" ]; then
  while IFS= read -r s || [ -n "$s" ]; do
    s="$(printf '%s' "$s" | tr -d '\r' | sed 's/^[ \t]*//;s/[ \t]*$//')"
    case "$s" in ""|"#"*) continue ;; esac
    ROOTS+=("$(dirname "$s")")
  done < "$SENTINELS"
fi

# ---- cron --------------------------------------------------------------------------
cron_running=0
for comm in /proc/[0-9]*/comm; do
  if read -r name < "$comm" 2>/dev/null && [ "$name" = "cron" ]; then cron_running=1; break; fi
done
if [ "$cron_running" -eq 1 ]; then ok "cron is running"; else bad "cron is not running"; fi

# ---- job files ---------------------------------------------------------------------
declare -A DESTS=() RETENTION=()
for jf in "${JOBFILES[@]}"; do
  if [ ! -f "$jf" ]; then bad "job file not found: $jf"; continue; fi
  before=$PROBLEMS
  n=0 lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    read -ra F <<<"$line"
    [ ${#F[@]} -gt 0 ] || continue
    case "${F[0]}" in "#"*) continue ;; esac
    n=$((n + 1))
    where="$jf:$lineno"
    op="${F[0]}"
    case "$op" in
      COPY|TAR|RSYNC)
        if [ "${F[1]:-}" != "FROM" ] || [ "${F[3]:-}" != "TO" ] || [ -z "${F[2]:-}" ] || [ -z "${F[4]:-}" ]; then
          bad "$where: malformed line, expected '$op FROM <src-dir> TO <dst-dir>': $line"; continue
        fi
        if [ "$op" = "RSYNC" ] && [ ${#F[@]} -gt 5 ]; then
          glob="${F[6]:-}"; glob="${glob%\'}"; glob="${glob#\'}"; glob="${glob%\"}"; glob="${glob#\"}"
          if [ ${#F[@]} -ne 7 ] || [ "${F[5]}" != "ONLY" ] || [ -z "$glob" ] || [[ "$glob" == */* ]]; then
            bad "$where: malformed RSYNC option, expected 'ONLY <glob>' (no / or spaces in the glob): $line"; continue
          fi
        elif [ ${#F[@]} -ne 5 ]; then
          bad "$where: unexpected extra fields: $line"; continue
        fi
        if [[ "${F[2]}" != /* ]] || [[ "${F[4]}" != /* ]]; then
          bad "$where: paths must be absolute: $line"; continue
        fi
        [ -d "${F[2]}" ] || bad "$where: source directory does not exist: ${F[2]}"
        DESTS["${F[4]}"]="$where"
        ;;
      PURGE)
        if [ "${F[1]:-}" != "FOLDER" ] || [ "${F[3]:-}" != "USING" ] || [ -z "${F[2]:-}" ] || [ -z "${F[4]:-}" ] || [ ${#F[@]} -ne 5 ]; then
          bad "$where: malformed line, expected 'PURGE FOLDER <dir> USING <retention.yml>': $line"; continue
        fi
        if [[ "${F[2]}" != /* ]]; then bad "$where: paths must be absolute: $line"; continue; fi
        # The folder may not exist before the first backup ran; it is tested like a destination.
        DESTS["${F[2]}"]="$where"
        RETENTION["${F[4]}"]="$where"
        ;;
      *)
        bad "$where: unknown operation '$op': $line"; continue
        ;;
    esac
  done < "$jf"
  if [ "$PROBLEMS" -eq "$before" ]; then ok "$jf: $n job line(s) parse, sources exist"; fi
done

# ---- retention files ---------------------------------------------------------------
RETENTION_CHECK='
import re, sys
import yaml
from pydantic import BaseModel
from retention_rules import PolicyBuilder

class RetentionPolicySettings(BaseModel):   # same model as apply_retention_policy.py
    filename_pattern: str
    retention_policy: dict

try:
    with open(sys.argv[1]) as f:
        settings = RetentionPolicySettings(**yaml.safe_load(f))
    if re.compile(settings.filename_pattern).groups != 2:
        raise ValueError("filename_pattern needs exactly two groups (date, time)")
    PolicyBuilder().build(settings.retention_policy)
except Exception as e:
    text = str(e).splitlines()
    print(type(e).__name__ + ": " + (text[0] if text else ""))
    sys.exit(1)
'
for rf in "${!RETENTION[@]}"; do
  if [ ! -f "$rf" ]; then bad "${RETENTION[$rf]}: retention file not found: $rf"; continue; fi
  if msg="$(python -c "$RETENTION_CHECK" "$rf" 2>&1)"; then
    ok "retention file loads: $rf"
  else
    bad "${RETENTION[$rf]}: retention file does not load: $rf: $msg"
  fi
done

# ---- destinations writable -----------------------------------------------------------
TS="$(date +%Y%m%d_%H%M%S)"
while IFS= read -r dest; do
  [ -n "$dest" ] || continue
  where="${DESTS[$dest]}"
  d="${dest%/}"; [ -n "$d" ] || d=/
  if [[ "/$d/" == *"/../"* ]]; then bad "$where: destination contains '..': $dest"; continue; fi
  root=""
  for r in "${ROOTS[@]}"; do
    r="${r%/}"
    if [ "$d" = "$r" ] || [[ "$d" == "$r"/* ]]; then
      if [ ${#r} -gt ${#root} ]; then root="$r"; fi
    fi
  done
  if [ -z "$root" ]; then
    bad "$where: destination is not under a sentinel-protected mount, not tested: $dest"; continue
  fi
  if [ -e "$d" ] && [ ! -d "$d" ]; then bad "$where: destination exists but is not a directory: $dest"; continue; fi
  probe="$d"
  while [ ! -d "$probe" ] && [ "$probe" != "$root" ]; do probe="$(dirname "$probe")"; done
  tmp="$probe/.selftest_${TS}_$$"
  if err="$( { : > "$tmp"; } 2>&1 )"; then
    rm -f "$tmp"
    if [ "$probe" = "$d" ]; then ok "destination writable: $dest"
    else ok "destination writable: $dest (does not exist yet, tested in $probe)"; fi
  else
    rm -f "$tmp" 2>/dev/null
    bad "$where: destination not writable: $dest (tested in $probe): ${err##*: }"
  fi
done < <(printf '%s\n' "${!DESTS[@]}" | LC_ALL=C sort)

# ---- result --------------------------------------------------------------------------
if [ "$PROBLEMS" -eq 0 ]; then
  echo "SELFTEST PASSED"
  exit 0
fi
echo "SELFTEST FAILED: $PROBLEMS problem(s)"
exit 1
