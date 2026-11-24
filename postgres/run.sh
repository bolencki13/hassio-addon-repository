#!/usr/bin/env bash
set -Eeo pipefail

export PGDATA=/data/postgres

if [ "$(id -u)" = '0' ]; then
    # The Supervisor writes options.json readable by root only, so read it
    # here; gosu keeps these variables when it switches to the postgres user.
    OPTIONS=/data/options.json
    POSTGRES_USER="$(jq -r '.user // empty' "$OPTIONS")"
    POSTGRES_PASSWORD="$(jq -r '.password // empty' "$OPTIONS")"
    POSTGRES_DB="$(jq -r '.database // empty' "$OPTIONS")"
    export POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB

    /usr/local/bin/import.sh
    mkdir -p "$PGDATA"
    chown postgres:postgres /data "$PGDATA"
    # Safety net: postgres refuses to run on files it doesn't own. With the
    # image's uid matching earlier addon versions this normally finds
    # nothing (same approach as the official docker-entrypoint.sh).
    find "$PGDATA" \! -user postgres -exec chown postgres:postgres '{}' +
    exec gosu postgres "$0" "$@"
fi

if [ -z "${POSTGRES_USER:-}" ] || [ -z "${POSTGRES_PASSWORD:-}" ] || [ -z "${POSTGRES_DB:-}" ]; then
    echo "run.sh: the user, password and database options must all be set. Nothing has been changed." >&2
    exit 1
fi

/usr/local/bin/upgrade.sh

exec docker-entrypoint.sh postgres
