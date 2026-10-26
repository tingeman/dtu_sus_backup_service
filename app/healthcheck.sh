#!/bin/sh
# Docker HEALTHCHECK: light and read-only. Healthy when every sentinel file is present
# and cron is running. Output is kept by Docker (docker inspect ... .State.Health).
# Exit 0 healthy, 1 unhealthy.

/backup/check_sentinels.sh /backup/sentinels.conf || exit 1

# procps is not installed, so look at /proc/<pid>/comm.
for comm in /proc/[0-9]*/comm; do
  if read -r name < "$comm" 2>/dev/null && [ "$name" = "cron" ]; then
    exit 0
  fi
done
echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: cron is not running"
exit 1
