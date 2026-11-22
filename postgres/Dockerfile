# Fixed base image: the upgrade logic relies on this exact Debian base (it
# installs the PostgreSQL 12 binaries from the same apt repository). The
# Supervisor's BUILD_FROM / build.json is deprecated and may hand us its own
# Alpine base instead, so it is deliberately not used. Multi-arch, so the
# host's architecture (amd64 or aarch64) is picked automatically.
FROM postgres:18-bookworm

ENV DEBIAN_FRONTEND=noninteractive

# Pull in the previous major version's server binaries (built for this same
# Debian base, so they share compatible libraries) purely so pg_upgrade can
# migrate an existing v12 data directory the first time this image starts.
# This does not create or touch any cluster at build time.
RUN mkdir -p /etc/postgresql-common \
    && echo 'create_main_cluster = false' > /etc/postgresql-common/createcluster.conf \
    && apt-get update \
    && apt-get install -y --no-install-recommends curl jq postgresql-12 \
    && rm -rf /var/lib/apt/lists/*

# Earlier versions of this addon (Alpine-based) ran postgres as uid/gid 70,
# so existing data directories are owned by 70. The Debian image uses 999.
# Match the old ids so existing data stays readable without changing its
# ownership.
RUN groupmod -g 70 postgres \
    && usermod -u 70 -g 70 postgres \
    && chown -R postgres:postgres /var/lib/postgresql /run/postgresql

ENV PGDATA=/data/postgres

COPY run.sh import.sh upgrade.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/run.sh /usr/local/bin/import.sh /usr/local/bin/upgrade.sh

EXPOSE 5432
ENTRYPOINT ["run.sh"]
