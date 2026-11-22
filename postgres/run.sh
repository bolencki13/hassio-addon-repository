#!/usr/bin/env bash
set -Eeo pipefail

OPTIONS=/data/options.json
export POSTGRES_USER="$(jq -r '.user' "$OPTIONS")"
export POSTGRES_PASSWORD="$(jq -r '.password' "$OPTIONS")"
export POSTGRES_DB="$(jq -r '.database' "$OPTIONS")"
export PGDATA=/data/postgres

if [ "$(id -u)" = '0' ]; then
    /usr/local/bin/import.sh
    mkdir -p "$PGDATA"
    chown postgres:postgres /data "$PGDATA"
    # Safety net: postgres refuses to run on files it doesn't own. With the
    # image's uid matching earlier addon versions this normally finds
    # nothing (same approach as the official docker-entrypoint.sh).
    find "$PGDATA" \! -user postgres -exec chown postgres:postgres '{}' +
    exec gosu postgres "$0" "$@"
fi

/usr/local/bin/upgrade.sh

exec docker-entrypoint.sh postgres
