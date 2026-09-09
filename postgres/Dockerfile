ARG BUILD_FROM
FROM ${BUILD_FROM}

ENV DEBIAN_FRONTEND=noninteractive

# Pull in the previous major version's server binaries (built for this same
# Debian base, so they share compatible libraries) purely so pg_upgrade can
# migrate an existing v12 data directory the first time this image starts.
# This does not create or touch any cluster at build time.
RUN mkdir -p /etc/postgresql-common \
    && echo 'create_main_cluster = false' > /etc/postgresql-common/createcluster.conf \
    && apt-get update \
    && apt-get install -y --no-install-recommends jq postgresql-12 \
    && rm -rf /var/lib/apt/lists/*

ENV PGDATA=/data/postgres

COPY run.sh /usr/local/bin/run.sh
COPY upgrade.sh /usr/local/bin/upgrade.sh
RUN chmod +x /usr/local/bin/run.sh /usr/local/bin/upgrade.sh

EXPOSE 5432
ENTRYPOINT ["run.sh"]
