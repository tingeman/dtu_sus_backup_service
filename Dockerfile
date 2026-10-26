# Base image: python:3.12-slim, pinned by digest (index digest, multi-arch).
# To update: docker buildx imagetools inspect python:3.12-slim, then regenerate the
# lock file inside the same base image (see README).
FROM python:3.12-slim@sha256:a0f57064cbdcd6285fa45f51237ab0b35ea8ebaed06a1f5973e89e19dfb86704

# Only what the scripts use. tar, gzip, find and coreutils are part of the base image.
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash cron rsync \
    && rm -rf /var/lib/apt/lists/*

COPY ./entrypoint.sh /entrypoint.sh

WORKDIR /backup

COPY ./app/backup_script.sh ./backup_script.sh
COPY ./app/check_sentinels.sh ./check_sentinels.sh
COPY ./app/apply_retention_policy.py ./apply_retention_policy.py
COPY ./app/selftest.sh ./selftest.sh
COPY ./app/healthcheck.sh ./healthcheck.sh
COPY ./requirements.txt ./requirements.txt

RUN set -ex && \
    python -m pip install --no-cache-dir --require-hashes -r ./requirements.txt

RUN chmod +x /entrypoint.sh /backup/backup_script.sh /backup/check_sentinels.sh /backup/apply_retention_policy.py \
    /backup/selftest.sh /backup/healthcheck.sh

# Healthy = every sentinel present and cron running (see healthcheck.sh). start-interval
# (Docker Engine 25+) checks every 2 s during the start period, so `docker compose up --wait`
# does not wait a full interval.
HEALTHCHECK --interval=60s --timeout=10s --start-period=20s --start-interval=2s --retries=3 \
    CMD ["/backup/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]
