# backup-service

A small container image that runs scheduled backup and sync jobs with cron. It copies,
archives and prunes folders on mounted storage. It contains no credentials and mounts
nothing itself: the host mounts any network shares and bind-mounts them into the container.

What is in the image: `bash`, `cron`, `rsync`, Python 3.12 with `PyYAML`, `pydantic` and
`retention-rules` (hash-locked), and the scripts below. What is not: any share-mounting
tool, `sudo`, `curl`, editors. All configuration is bind-mounted at run time.

## Container paths

| Path | Purpose |
|---|---|
| `/backup/backup_script.sh` | job runner; argument 1 is the job file (default `/backup/backup_folders.conf`) |
| `/backup/check_sentinels.sh` | sentinel check, used by the entrypoint and the job runner |
| `/backup/apply_retention_policy.py` | retention policy for `PURGE` jobs |
| `/backup/selftest.sh` | self-test of a configured container, run with `docker exec` (see below) |
| `/backup/healthcheck.sh` | the Docker `HEALTHCHECK` command (see below) |
| `/backup/backup_folders.conf`, `/backup/sync_folders.conf` | job files (mount read-only); any path works if the cron entry names it |
| `/backup/retention_config.yml` | retention policy (mount read-only) |
| `/backup/sentinels.conf` | list of sentinel files (mount read-only), required |
| `/app/cron_jobs/` | cron files, copied to `/etc/cron.d` at start (mount read-only) |
| `/mnt/src/<name>` | convention for read-only sources (volumes or host folders) to back up |
| destination mounts | any path, for example `/mnt/dest_a`; the image hardcodes none |
| `/var/log/backup.log` | where cron output goes if the cron files redirect it there (see below) |

The entrypoint is `/entrypoint.sh`. It runs the sentinel check, installs the cron files
and runs `cron -f` in the foreground as root.

## Sentinels (fail closed)

If a share is not mounted, a bind mount shows an empty directory on the host disk and
backups would be written there silently. To prevent this, every mount that is written to
has a sentinel file at its root, for example `.mounted_dest_a`, created by whoever sets up
the host mount, and listed in `/backup/sentinels.conf`:

```
# one absolute sentinel file path per line; blank lines and lines starting with # are ignored
/mnt/dest_a/.mounted_dest_a
/mnt/dest_b/.mounted_dest_b
```

- At start, `entrypoint.sh` exits non-zero if the file is missing or empty, or if any
  listed sentinel does not exist. It logs which one. Cron is not started.
- Before every job line, `backup_script.sh` checks the same list again (cron jobs get no
  environment variables, so it is a file). If anything is missing it logs the path, runs
  no further jobs, writes nothing, and exits non-zero.

Mount the share read-write on the host with `rslave` propagation so that a remount on the
host reaches the running container.

## Job files

One job per line, fields separated by single spaces. Lines starting with `#` and blank
lines are ignored. End the file with a newline. Source folders must exist (a missing
source is logged and skipped). Destination folders are created.

```
COPY  FROM <src-dir> TO <dst-dir>
TAR   FROM <src-dir> TO <dst-dir>
RSYNC FROM <src-dir> TO <dst-dir> [ONLY <glob>]
PURGE FOLDER <dir> USING <retention-config.yml>
```

- `COPY`: `cp -r <src>/* <dst>/`.
- `TAR`: creates `<dst>/<basename of src>_<YYYYMMDD_HHMMSS>.tar.gz` of the source's content.
- `RSYNC`: `rsync -a --chmod=ugo=rw <src>/ <dst>/`. No `--delete`: files removed at the
  source stay at the destination.
- `RSYNC ... ONLY <glob>`: copy only top-level files whose name matches the glob. Files
  ending in `.partial`, dot files and subdirectories are never copied. The glob may be
  wrapped in single or double quotes, must not contain `/` or spaces, for example
  `RSYNC FROM /mnt/src/dumps TO /mnt/dest_a/dumps ONLY '*.tar.gz'`. This is for producers
  that write a file as `<name>.partial` and rename it when complete.
- `PURGE FOLDER <dir> USING <file>`: applies the retention policy to the entries directly
  inside `<dir>`: files, and folders, which are removed recursively. A symbolic link is
  removed itself, never followed. Entries whose name has no timestamp are left alone.

### Retention config

```yaml
# The first group of the pattern is the date (YYYYMMDD), the second the time (HHMMSS).
filename_pattern: (\d{8})_(\d{6})
retention_policy:
  rules:
    - applies_for: "3D"      # entries younger than 3 days ...
      retain_every: "H/6"    # ... keep one every 6 hours
    - applies_for: "14D"
      retain_every: "D"
    - applies_for: "6M"
      retain_every: "W"
  reuse: true
  retain: "newest"
```

The `retention_policy` block is passed to the `retention-rules` package (`PolicyBuilder`);
see its documentation for the syntax. `apply_retention_policy.py [--dry_run] <folder> <config>`
can also be run by hand; `--dry_run` only logs what it would delete or keep.

## Cron files

Files in `/app/cron_jobs/` are copied to `/etc/cron.d/` at start. Rules of cron.d:

- File names contain only letters, digits, `_` and `-`. Debian cron silently skips names
  with a `.`, so use no extension.
- Owner root, mode 644 (the entrypoint sets this), a blank line at the end (added).
- Format: `min hour day month weekday user command`, times are in the container's time
  zone (UTC unless set).
- Cron jobs get no environment variables from the container.

Example:

```
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

0 1 * * * root /backup/backup_script.sh /backup/backup_folders.conf >> /var/log/backup.log 2>&1
*/15 * * * * root /backup/backup_script.sh /backup/sync_folders.conf >> /var/log/backup.log 2>&1
```

## Log

Job output goes wherever the cron line sends it; the example appends to
`/var/log/backup.log` inside the container. Entrypoint output is the container log
(`docker logs`). Mount a volume at `/var/log` (or a file at `/var/log/backup.log`) to keep
the job log across container re-creation. Rotate it on the outside.

## Healthcheck

The image has a Docker `HEALTHCHECK` that runs `/backup/healthcheck.sh` every 60 s
(timeout 10 s, 3 retries, 20 s start period, and a check every 2 s during the start period).
It is light and read-only: healthy means every sentinel in `/backup/sentinels.conf` exists
and `cron` is running. The failing reason is in `docker inspect` under `.State.Health.Log`.

The 2 s start-up interval (`--start-interval`) needs Docker Engine 25 or newer. The hosts run
a current Docker Engine from Docker's apt repository. On an older engine the option is
ignored and the container becomes healthy after the first regular interval instead.

`docker compose up -d --wait` waits for the container to be healthy, so a deployment fails
(instead of reporting success) when a share is not mounted.

## Self-test

`/backup/selftest.sh` checks a configured, running container, for use on the host after a
deployment:

```
docker exec <container> /backup/selftest.sh
docker exec <container> /backup/selftest.sh --sentinels <sentinel-list> <job-file> [<job-file> ...]
```

Without arguments it uses `/backup/sentinels.conf`, `/backup/backup_folders.conf` and
`/backup/sync_folders.conf`. It prints one line per check (`ok:` or `FAIL:`, naming the file,
line and cause) and ends with `SELFTEST PASSED` (exit 0) or `SELFTEST FAILED: <n> problem(s)`
(exit 1). It checks:

- all sentinels exist, and cron is running;
- every job line is a known operation with the expected fields, and every source folder
  exists;
- every retention file used by a `PURGE` line exists and loads (YAML, the same settings
  model and `PolicyBuilder` as `apply_retention_policy.py`);
- every distinct destination (and `PURGE` folder) is writable. It creates and deletes a file
  `.selftest_<timestamp>_<pid>` in the destination, or, when the destination does not exist
  yet, in its nearest existing parent. It never creates the destination, and it only writes
  below a sentinel's directory: a destination outside the sentinel-protected mounts is
  reported as a problem and not touched.

Apart from that temporary file it changes nothing.

## Tests

`tests/run.sh <image>` runs behaviour tests against a built image with the docker CLI only
(Linux or WSL). Every container runs with `--network none`, and all containers and temporary
folders are removed at the end. It covers: image contents (tools present and absent, Python
packages, script syntax), the entrypoint with and without sentinels, the job runner (sentinel
check, `RSYNC ... ONLY`, plain `RSYNC`, `TAR`, `COPY`), the retention policy (old folders,
symbolic links, recent entries), the healthcheck and the self-test. It prints `PASS:` or
`FAIL:` per check and ends with `ALL <n> TESTS PASSED` (exit 0) or `<m> OF <n> TESTS FAILED`
(exit 1).

```
docker build -t backup-service:local .
tests/run.sh backup-service:local
```

The deployment's build script runs `tests/run.sh` automatically on the image it builds from
a checkout of a commit or tag, and writes no release bundle when it fails. Run it yourself
before tagging a release.

## How a deployment uses this

- Mount the sentinel list, job files, retention policy and cron files as shown below, and
  start the container normally. The image's healthcheck applies without any compose option.
- After the container is up, run `docker exec <container> /backup/selftest.sh` and fail the
  deployment if it exits non-zero. With Ansible this is a post-start check on the container.
- Use `docker compose up -d --wait` so that a container that is not healthy fails the
  deployment.

## Build

The Dockerfile pins the base image by digest and installs the Python packages from a hash
lock (`pip install --require-hashes`).

```
docker build -t backup-service:local .
```

To change the Python packages, edit `requirements.in` and regenerate the lock inside the
pinned base image, so that it matches the image's Python:

```
docker run --rm -v "$PWD":/w -w /w python:3.12-slim@sha256:<digest from Dockerfile> \
  sh -c 'pip install pip-tools && pip-compile --generate-hashes -o requirements.txt requirements.in'
```

## Required mounts

| Mount | Mode | Notes |
|---|---|---|
| `/backup/sentinels.conf` | ro | required, see above |
| job files and `/backup/retention_config.yml` | ro | |
| `/app/cron_jobs` | ro | |
| sources under `/mnt/src/<name>` | ro | volumes or host folders |
| destinations | rw | host mounts with a sentinel at the root, `rslave` propagation |

The container needs no extra capabilities, no privileged mode and no host networking.
It runs as root, which cron needs.

## Example compose service

```yaml
services:
  backup-service:
    image: backup-service:local          # or the release you loaded
    restart: unless-stopped
    entrypoint: ["/entrypoint.sh"]
    volumes:
      - ./config/backup_folders.conf:/backup/backup_folders.conf:ro
      - ./config/sync_folders.conf:/backup/sync_folders.conf:ro
      - ./config/retention_config.yml:/backup/retention_config.yml:ro
      - ./config/sentinels.conf:/backup/sentinels.conf:ro
      - ./config/cron_jobs:/app/cron_jobs:ro
      - source_volume:/mnt/src/source-name:ro
      - type: bind
        source: /host/mount/dest_a
        target: /mnt/dest_a
        bind:
          propagation: rslave
      - backup_logs:/var/log

volumes:
  source_volume:
    external: true
  backup_logs:
```
