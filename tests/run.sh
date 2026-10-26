#!/bin/bash
# Behaviour tests of the backup-service image. Run on the workstation (Linux or WSL) with
# the docker CLI against a built image:
#
#   tests/run.sh backup-service:local
#
# Every container runs with --network none, has a name starting with a unique prefix, and
# is removed at the end together with the temporary directories (files that containers
# created there as root are deleted from inside a container). Nothing else is touched.
# Each check prints "PASS: <name>" or "FAIL: <name>: <reason>". The last line is
# "ALL <n> TESTS PASSED" (exit 0) or "<m> OF <n> TESTS FAILED" (exit 1).
set -euo pipefail

IMAGE="${1:-}"
[ -n "$IMAGE" ] && [ $# -eq 1 ] || { echo "Usage: $0 <image>" >&2; exit 2; }
command -v docker >/dev/null || { echo "docker not found" >&2; exit 2; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "image not found: $IMAGE" >&2; exit 2; }

PFX="backup-test-$$"
T="$(mktemp -d "${TMPDIR:-/tmp}/backup-test.XXXXXX")"

cleanup() {
  local rc=$?
  trap - EXIT
  local ids
  ids="$(docker ps -aq --filter "name=${PFX}-" 2>/dev/null || true)"
  [ -z "$ids" ] || docker rm -f $ids >/dev/null 2>&1 || true
  if [ -d "$T" ]; then
    # containers wrote as root: delete from inside a container, then remove what is left
    docker run --rm --network none --entrypoint sh -v "$T:/t" "$IMAGE" -c 'find /t -mindepth 1 -delete' >/dev/null 2>&1 || true
    rm -rf "$T" 2>/dev/null || echo "WARNING: could not remove $T" >&2
  fi
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---- helpers -------------------------------------------------------------------------

TESTNAME=""
fail_t() { echo "$*"; exit 1; }                       # fail the current test (runs in a subshell)
expect() { [ "$2" = "$3" ] || fail_t "$1: expected [$3], got [$2]"; }
contains() { case "$2" in *"$3"*) ;; *) fail_t "$1: output does not contain [$3]: $2" ;; esac; }
cname() { echo "$PFX-$TESTNAME${1:+-$1}"; }
sorted() { LC_ALL=C sort; }

# Plain container for image-content checks
plain() { docker run --rm --network none --entrypoint sh "$IMAGE" -c "$1"; }

# Entries under a directory as "<type> <path>", without the sentinel files. Listed by a
# container (as root): rsync --chmod=ugo=rw leaves directories the workstation user cannot enter.
listing() {
  docker run --rm --network none --entrypoint find -v "$1:/t:ro" -w /t "$IMAGE" . -mindepth 1 -not -name '.mounted_*' -printf '%y %P\n' | sorted
}

# Fresh environment directory $E with two destination mounts (a, b), a source (src) and
# the standard config. MNT: mounts without the sentinel list; SM: the sentinel list mount.
mkenv() {
  E="$T/$1"
  mkdir -p "$E"/{a,b,c,src,cron,conf,alt}
  touch "$E/a/.mounted_a" "$E/b/.mounted_b"
  printf '%s\n' '# test sentinels' '/mnt/dest_a/.mounted_a' '/mnt/dest_b/.mounted_b' > "$E/conf/sentinels.conf"
  printf '%s\n' 'SHELL=/bin/sh' '0 1 * * * root /backup/backup_script.sh /backup/backup_folders.conf' > "$E/cron/cron_test"
  cat > "$E/conf/retention.yml" <<'YML'
filename_pattern: (\d{8})_(\d{6})
retention_policy:
  rules:
    - applies_for: "3D"
      retain_every: "H/6"
    - applies_for: "14D"
      retain_every: "D"
    - applies_for: "6M"
      retain_every: "W"
  reuse: true
  retain: "newest"
YML
  : > "$E/src/.hidden"
  : > "$E/src/.hidden.tar.gz"
  : > "$E/src/a.tar.gz"
  : > "$E/src/b.tar.gz.partial"
  : > "$E/src/d.txt"
  mkdir -p "$E/src/sub"; : > "$E/src/sub/c.tar.gz"
  SM=(-v "$E/conf/sentinels.conf:/backup/sentinels.conf:ro")
  MNT=(-v "$E/a:/mnt/dest_a" -v "$E/b:/mnt/dest_b" -v "$E/src:/mnt/src/data:ro")
}

# docker run --rm with the environment's mounts: dr [docker options] IMAGE [command...]
dr() { docker run --rm --network none --name "$(cname "$RANDOM")" ${SM[@]+"${SM[@]}"} "${MNT[@]}" "$@"; }

# Run the job runner on a job file given as text (one line per argument)
run_jobs() {
  printf '%s\n' "$@" > "$E/conf/job.conf"; echo >> "$E/conf/job.conf"
  dr -v "$E/conf/job.conf:/backup/job.conf:ro" --entrypoint /backup/backup_script.sh "$IMAGE" /backup/job.conf
}

wait_until() {   # wait_until <tries> <cmd...>: run cmd every 0.5 s until it succeeds
  local n=$1; shift
  while [ "$n" -gt 0 ]; do "$@" >/dev/null 2>&1 && return 0; sleep 0.5; n=$((n - 1)); done
  return 1
}
health_is() { [ "$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null)" = "$2" ]; }

PASSED=0 FAILED=0
run_test() {   # run_test <name> <function> [args...]
  local name="$1" fn="$2"; shift 2
  local out rc=0
  TESTNAME="$(printf '%s' "$name" | tr -c 'A-Za-z0-9\n' '-' | cut -c1-40)"
  out="$($fn "$@" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    PASSED=$((PASSED + 1)); echo "PASS: $name"
  else
    FAILED=$((FAILED + 1)); echo "FAIL: $name: $(printf '%s' "$out" | head -n 12 | sed '2,$s/^/    /')"
  fi
}

# ---- image contents ------------------------------------------------------------------

t_has()   { plain "command -v $1" >/dev/null || fail_t "$1 is missing"; }
t_lacks() { ! plain "command -v $1" >/dev/null 2>&1 || fail_t "$1 is present"; }

t_python_imports() {
  docker run --rm --network none --entrypoint python "$IMAGE" -c \
    'import yaml, pydantic, pydantic_settings, retention_rules' 2>&1 || fail_t "import failed"
}

t_syntax() {
  local f
  for f in /entrypoint.sh /backup/backup_script.sh /backup/check_sentinels.sh /backup/healthcheck.sh; do
    plain "sh -n $f && bash -n $f" 2>&1 || fail_t "syntax error in $f"
  done
  plain "bash -n /backup/selftest.sh" 2>&1 || fail_t "syntax error in /backup/selftest.sh"
  docker run --rm --network none --entrypoint python "$IMAGE" -c \
    'import ast; ast.parse(open("/backup/apply_retention_policy.py").read())' 2>&1 || fail_t "syntax error in apply_retention_policy.py"
}

t_executable() {
  local f
  for f in /entrypoint.sh /backup/backup_script.sh /backup/check_sentinels.sh /backup/selftest.sh /backup/healthcheck.sh /backup/apply_retention_policy.py; do
    plain "test -x $f" || fail_t "$f is not executable"
  done
}

t_healthcheck_defined() {
  local hc
  hc="$(docker inspect -f '{{json .Config.Healthcheck}}' "$IMAGE")"
  contains "image healthcheck" "$hc" "/backup/healthcheck.sh"
}

# ---- entrypoint ----------------------------------------------------------------------

t_entry_ok() {
  mkenv entry_ok
  local name running files mode cronfile
  name="$(cname)"
  docker run -d --network none --name "$name" "${SM[@]}" "${MNT[@]}" -v "$E/cron:/app/cron_jobs:ro" "$IMAGE" >/dev/null || fail_t "could not start"
  wait_until 40 sh -c "docker logs '$name' 2>&1 | grep -q 'cron.d/ updated'" || fail_t "entrypoint did not finish: $(docker logs "$name" 2>&1 | tail -n 5)"
  sleep 2
  running="$(docker inspect -f '{{.State.Running}}' "$name")"
  files="$(docker exec "$name" ls /etc/cron.d)"
  mode="$(docker exec "$name" stat -c '%a %U' /etc/cron.d/cron_test)"
  cronfile="$(docker exec "$name" cat /etc/cron.d/cron_test)"
  docker rm -f "$name" >/dev/null
  expect "container running" "$running" "true"
  contains "cron.d" "$files" "cron_test"
  expect "cron file mode and owner" "$mode" "644 root"
  contains "cron file" "$cronfile" "/backup/backup_script.sh"
}

# Entrypoint that must refuse to start: exit non-zero, no cron file installed, nothing written
entry_must_fail() {
  local name out rc=0 changes
  name="$(cname)"
  out="$(docker run --network none --name "$name" ${SM[@]+"${SM[@]}"} "${MNT[@]}" -v "$E/cron:/app/cron_jobs:ro" "$IMAGE" 2>&1)" || rc=$?
  changes="$(docker diff "$name" || true)"
  docker rm -f "$name" >/dev/null
  [ "$rc" -ne 0 ] || fail_t "exit code 0, expected non-zero: $out"
  case "$changes" in *"/etc/cron.d/cron_test"*) fail_t "a cron file was installed" ;; esac
  expect "files written to the destinations" "$(listing "$E/a"; listing "$E/b")" ""
  ENTRY_OUT="$out"
}

t_entry_missing_sentinel() { mkenv entry_missing; rm "$E/b/.mounted_b"; entry_must_fail; contains "log" "$ENTRY_OUT" ".mounted_b"; }
t_entry_empty_list() { mkenv entry_empty; printf '%s\n' '# nothing' '' > "$E/conf/sentinels.conf"; entry_must_fail; contains "log" "$ENTRY_OUT" "empty"; }
t_entry_no_list() { mkenv entry_nolist; SM=(); entry_must_fail; contains "log" "$ENTRY_OUT" "not found"; }

# ---- backup_script.sh ----------------------------------------------------------------

t_bs_sentinel_missing() {
  mkenv bs_sentinel
  rm "$E/b/.mounted_b"
  local out rc=0
  out="$(run_jobs 'COPY FROM /mnt/src/data TO /mnt/dest_a/out' 'TAR FROM /mnt/src/data TO /mnt/dest_b/out' 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail_t "exit code 0, expected non-zero"
  contains "log" "$out" ".mounted_b"
  expect "destination a" "$(listing "$E/a")" ""
  expect "destination b" "$(listing "$E/b")" ""
}

t_bs_rsync_only() {
  mkenv bs_only
  run_jobs "RSYNC FROM /mnt/src/data TO /mnt/dest_a/dumps ONLY '*.tar.gz'" \
           'RSYNC FROM /mnt/src/data TO /mnt/dest_a/dumps2 ONLY "*.tar.gz"' >/dev/null 2>&1 || fail_t "job runner failed"
  expect "copied entries" "$(listing "$E/a")" "$(printf '%s\n' 'd dumps' 'f dumps/a.tar.gz' 'd dumps2' 'f dumps2/a.tar.gz' | sorted)"
}

t_bs_rsync_plain() {
  mkenv bs_plain
  run_jobs 'RSYNC FROM /mnt/src/data TO /mnt/dest_a/all' >/dev/null 2>&1 || fail_t "job runner failed"
  expect "copied entries" "$(listing "$E/a")" "$(printf '%s\n' 'd all' 'f all/.hidden' 'f all/.hidden.tar.gz' 'f all/a.tar.gz' 'f all/b.tar.gz.partial' 'f all/d.txt' 'd all/sub' 'f all/sub/c.tar.gz' | sorted)"
}

t_bs_tar() {
  mkenv bs_tar
  run_jobs 'TAR FROM /mnt/src/data TO /mnt/dest_a/tars' >/dev/null 2>&1 || fail_t "job runner failed"
  local files tarball
  files="$(cd "$E/a/tars" && ls)"
  [[ "$files" =~ ^data_[0-9]{8}_[0-9]{6}\.tar\.gz$ ]] || fail_t "unexpected tarball name(s): $files"
  tarball="$(tar -tzf "$E/a/tars/$files")"
  contains "tarball" "$tarball" "a.tar.gz"
  contains "tarball" "$tarball" "sub/c.tar.gz"
}

t_bs_copy() {
  mkenv bs_copy
  run_jobs 'COPY FROM /mnt/src/data TO /mnt/dest_a/copy' >/dev/null 2>&1 || fail_t "job runner failed"
  expect "copied entries" "$(listing "$E/a")" "$(printf '%s\n' 'd copy' 'f copy/a.tar.gz' 'f copy/b.tar.gz.partial' 'f copy/d.txt' 'd copy/sub' 'f copy/sub/c.tar.gz' | sorted)"
}

# ---- retention -----------------------------------------------------------------------

t_retention() {
  mkenv retention
  local recent
  recent="$(date -u +%Y%m%d_%H%M%S)"
  mkdir -p "$E/a/purge/20010101_000000/deep/er" "$E/a/purge/$recent" "$E/a/keep_target"
  : > "$E/a/purge/20010101_000000/deep/er/file.txt"
  : > "$E/a/purge/$recent/data.txt"
  : > "$E/a/purge/notes.txt"
  : > "$E/a/keep_target/precious.txt"
  ln -s /mnt/dest_a/keep_target "$E/a/purge/20010103_000000"
  : > "$E/a/purge/20010104_000000.tar.gz"
  printf '%s\n' 'PURGE FOLDER /mnt/dest_a/purge USING /backup/retention_config.yml' > "$E/conf/job.conf"; echo >> "$E/conf/job.conf"
  dr -v "$E/conf/job.conf:/backup/job.conf:ro" -v "$E/conf/retention.yml:/backup/retention_config.yml:ro" \
    --entrypoint /backup/backup_script.sh "$IMAGE" /backup/job.conf >/dev/null 2>&1 || fail_t "job runner failed"
  expect "purge folder" "$(listing "$E/a/purge")" "$(printf '%s\n' "d $recent" "f $recent/data.txt" 'f notes.txt' | sorted)"
  [ -f "$E/a/keep_target/precious.txt" ] || fail_t "the symlink target was touched"
}

# ---- healthcheck ---------------------------------------------------------------------

t_healthcheck() {
  mkenv health
  local name rc
  name="$(cname)"
  docker run -d --network none --name "$name" --health-interval=2s --health-start-interval=1s --health-retries=2 \
    "${SM[@]}" "${MNT[@]}" -v "$E/cron:/app/cron_jobs:ro" "$IMAGE" >/dev/null || fail_t "could not start"
  wait_until 60 health_is "$name" healthy || fail_t "never healthy (status: $(docker inspect -f '{{.State.Health.Status}}' "$name"))"
  docker exec "$name" /backup/healthcheck.sh >/dev/null || fail_t "healthcheck command failed with all sentinels present"
  rm "$E/b/.mounted_b"
  rc=0; docker exec "$name" /backup/healthcheck.sh >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail_t "healthcheck command succeeded with a sentinel removed"
  wait_until 60 health_is "$name" unhealthy || fail_t "not unhealthy after removing a sentinel (status: $(docker inspect -f '{{.State.Health.Status}}' "$name"))"
}

# ---- selftest ------------------------------------------------------------------------

SELF_OK=0 SELF_E="" SELF_C=""

selftest_setup() {
  TESTNAME=selftest
  mkenv selftest
  SELF_E="$E"; SELF_C="$(cname)"
  touch "$E/c/.mounted_c"
  printf '%s\n' '/mnt/dest_c/.mounted_c' >> "$E/conf/sentinels.conf"
  mkdir -p "$E/b/sync"
  cat > "$E/conf/backup_folders.conf" <<'CONF'
# backup jobs
COPY  FROM /mnt/src/data TO /mnt/dest_a/copies
TAR   FROM /mnt/src/data TO /mnt/dest_a/tars/sub
RSYNC FROM /mnt/src/data TO /mnt/dest_b/sync
RSYNC FROM /mnt/src/data TO /mnt/dest_b/dumps ONLY '*.tar.gz'

PURGE FOLDER /mnt/dest_a/tars USING /backup/retention_config.yml
CONF
  cat > "$E/conf/sync_folders.conf" <<'CONF'
RSYNC FROM /mnt/src/data TO /mnt/dest_b/live
CONF
  cat > "$E/alt/bad_retention.yml" <<'CONF'
filename_pattern: (\d{8})
retention_policy: not-a-mapping
CONF
  docker run -d --network none --name "$SELF_C" "${SM[@]}" "${MNT[@]}" \
    -v "$E/c:/mnt/dest_c:ro" -v "$E/alt:/alt:ro" -v "$E/cron:/app/cron_jobs:ro" \
    -v "$E/conf/backup_folders.conf:/backup/backup_folders.conf:ro" \
    -v "$E/conf/sync_folders.conf:/backup/sync_folders.conf:ro" \
    -v "$E/conf/retention.yml:/backup/retention_config.yml:ro" "$IMAGE" >/dev/null 2>&1 || return 0
  wait_until 40 docker exec "$SELF_C" /backup/healthcheck.sh && SELF_OK=1
  return 0
}

# Run the selftest in the shared container; sets SOUT and SRC
self_run() {
  [ "$SELF_OK" -eq 1 ] || fail_t "the selftest container did not start"
  SRC=0
  SOUT="$(docker exec "$SELF_C" /backup/selftest.sh "$@" 2>&1)" || SRC=$?
}
alt_job() { E="$SELF_E"; printf '%s\n' "$@" > "$E/alt/job.conf"; echo >> "$E/alt/job.conf"; }

t_self_pass() {
  self_run
  [ "$SRC" -eq 0 ] || fail_t "expected exit 0, got $SRC: $SOUT"
  contains "output" "$SOUT" "SELFTEST PASSED"
  contains "output" "$SOUT" "does not exist yet"
  expect "leftover selftest files" "$(find "$SELF_E/a" "$SELF_E/b" -name '.selftest_*')" ""
  [ ! -e "$SELF_E/a/tars" ] || fail_t "the destination was created"
}

t_self_missing_sentinel() {
  rm "$SELF_E/b/.mounted_b"
  self_run
  touch "$SELF_E/b/.mounted_b"
  [ "$SRC" -ne 0 ] || fail_t "expected a non-zero exit"
  contains "output" "$SOUT" ".mounted_b"
  contains "output" "$SOUT" "SELFTEST FAILED"
}

t_self_missing_source() {
  alt_job 'COPY FROM /mnt/src/nope TO /mnt/dest_a/x'
  self_run /alt/job.conf
  [ "$SRC" -ne 0 ] || fail_t "expected a non-zero exit"
  contains "output" "$SOUT" "source directory does not exist: /mnt/src/nope"
  contains "output" "$SOUT" "SELFTEST FAILED: 1 problem(s)"
}

t_self_unwritable() {
  alt_job 'COPY FROM /mnt/src/data TO /mnt/dest_c/x'
  self_run /alt/job.conf
  [ "$SRC" -ne 0 ] || fail_t "expected a non-zero exit"
  contains "output" "$SOUT" "destination not writable: /mnt/dest_c/x"
  contains "output" "$SOUT" "SELFTEST FAILED: 1 problem(s)"
}

t_self_malformed() {
  alt_job 'FROBNICATE FROM /mnt/src/data TO /mnt/dest_a/x' \
          'COPY /mnt/src/data /mnt/dest_a/x' \
          "RSYNC FROM /mnt/src/data TO /mnt/dest_a/x ONLY"
  self_run /alt/job.conf
  [ "$SRC" -ne 0 ] || fail_t "expected a non-zero exit"
  contains "output" "$SOUT" "alt/job.conf:1: unknown operation 'FROBNICATE'"
  contains "output" "$SOUT" "alt/job.conf:2: malformed line"
  contains "output" "$SOUT" "alt/job.conf:3: malformed RSYNC option"
  contains "output" "$SOUT" "SELFTEST FAILED: 3 problem(s)"
}

t_self_outside_destination() {
  alt_job 'COPY FROM /mnt/src/data TO /tmp/outside'
  self_run /alt/job.conf
  [ "$SRC" -ne 0 ] || fail_t "expected a non-zero exit"
  contains "output" "$SOUT" "not under a sentinel-protected mount"
  expect "files in /tmp" "$(docker exec "$SELF_C" sh -c 'ls -A /tmp | grep selftest || true')" ""
}

t_self_retention() {
  alt_job 'PURGE FOLDER /mnt/dest_a/p1 USING /alt/missing.yml' 'PURGE FOLDER /mnt/dest_a/p2 USING /alt/bad_retention.yml'
  self_run /alt/job.conf
  [ "$SRC" -ne 0 ] || fail_t "expected a non-zero exit"
  contains "output" "$SOUT" "retention file not found: /alt/missing.yml"
  contains "output" "$SOUT" "retention file does not load: /alt/bad_retention.yml"
}

t_self_cron_down() {
  mkenv self_cron
  local name out rc=0 hrc=0
  name="$(cname)"
  docker run -d --network none --name "$name" "${SM[@]}" "${MNT[@]}" --entrypoint sleep "$IMAGE" 300 >/dev/null || fail_t "could not start"
  out="$(docker exec "$name" /backup/selftest.sh --sentinels /backup/sentinels.conf /nonexistent.conf 2>&1)" || rc=$?
  docker exec "$name" /backup/healthcheck.sh >/dev/null 2>&1 || hrc=$?
  [ "$rc" -ne 0 ] || fail_t "selftest exit code 0 without cron"
  contains "output" "$out" "cron is not running"
  [ "$hrc" -ne 0 ] || fail_t "healthcheck exit code 0 without cron"
}

# ---- run -----------------------------------------------------------------------------

for c in bash cron rsync; do run_test "image has $c" t_has "$c"; done
for c in mount.cifs sudo curl git; do run_test "image lacks $c" t_lacks "$c"; done
run_test "image python packages import" t_python_imports
run_test "image scripts have valid syntax" t_syntax
run_test "image scripts are executable" t_executable
run_test "image defines a healthcheck" t_healthcheck_defined

run_test "entrypoint with all sentinels keeps running and installs cron jobs" t_entry_ok
run_test "entrypoint refuses to start with a sentinel missing" t_entry_missing_sentinel
run_test "entrypoint refuses to start with an empty sentinel list" t_entry_empty_list
run_test "entrypoint refuses to start without a sentinel list" t_entry_no_list

run_test "backup_script stops and writes nothing with a sentinel missing" t_bs_sentinel_missing
run_test "backup_script RSYNC ONLY copies top-level matching files only" t_bs_rsync_only
run_test "backup_script RSYNC without ONLY copies everything" t_bs_rsync_plain
run_test "backup_script TAR creates a tarball" t_bs_tar
run_test "backup_script COPY copies the folder content" t_bs_copy

run_test "retention purges old entries, unlinks symlinks, keeps recent ones" t_retention

run_test "healthcheck follows the sentinels" t_healthcheck

selftest_setup
run_test "selftest passes in a prepared environment" t_self_pass
run_test "selftest reports a missing sentinel" t_self_missing_sentinel
run_test "selftest reports a missing source directory" t_self_missing_source
run_test "selftest reports an unwritable destination" t_self_unwritable
run_test "selftest reports malformed config lines" t_self_malformed
run_test "selftest reports a destination outside the mounts" t_self_outside_destination
run_test "selftest reports retention files that are missing or do not load" t_self_retention
run_test "selftest and healthcheck report cron not running" t_self_cron_down

TOTAL=$((PASSED + FAILED))
if [ "$FAILED" -eq 0 ]; then
  echo "ALL $TOTAL TESTS PASSED"
  exit 0
fi
echo "$FAILED OF $TOTAL TESTS FAILED"
exit 1
