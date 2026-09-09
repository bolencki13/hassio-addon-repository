#!/usr/bin/env bash
set -Eeo pipefail

OPTIONS=/data/options.json
export POSTGRES_USER="$(jq -r '.user' "$OPTIONS")"
export POSTGRES_PASSWORD="$(jq -r '.password' "$OPTIONS")"
export POSTGRES_DB="$(jq -r '.database' "$OPTIONS")"
export PGDATA=/data/postgres

if [ "$(id -u)" = '0' ]; then
    mkdir -p "$PGDATA"
    chown postgres:postgres /data "$PGDATA"
    exec gosu postgres "$0" "$@"
fi

/usr/local/bin/upgrade.sh

exec docker-entrypoint.sh postgres
