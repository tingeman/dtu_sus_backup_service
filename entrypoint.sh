#!/bin/sh

# Launch message from container
echo "$(date '+%Y-%m-%d %H:%M:%S') - Container started... entrypoint.sh invoked."

# The shares are mounted by the host and bind-mounted into the container. Each mount has a
# sentinel file at its root. Refuse to start if any is missing, otherwise backups would be
# written silently to the host disk. The sentinels are listed in /backup/sentinels.conf.
/backup/check_sentinels.sh /backup/sentinels.conf || {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Sentinel check failed, refusing to start."
    exit 1
}
echo "$(date '+%Y-%m-%d %H:%M:%S') - Sentinel check passed"

# For debian based distros, the cron jobs may be in separate files
# All cron files are copied to /etc/cron.d

# Copy cron jobs from /app/cron_jobs to /etc/cron.d
for cron_file in /app/cron_jobs/*; do
    if [ -f "$cron_file" ]; then
        cp "$cron_file" /etc/cron.d
        # ensure there is a blank line at the end of the file
        echo "" >> /etc/cron.d/$(basename "$cron_file")
        # set owner root and permissions 
        chown root:root /etc/cron.d/$(basename "$cron_file")
        chmod 0644 /etc/cron.d/$(basename "$cron_file")
    fi
done
echo "$(date '+%Y-%m-%d %H:%M:%S') - /etc/cron.d/ updated with custom cron jobs"

# exec "$@"    # This apparently doesn't work with cron, so we use the following instead

# Start cron in the foreground (debian distro)
exec cron -f
