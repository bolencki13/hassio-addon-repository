#!/usr/bin/env bash
set -Eeo pipefail

OLD_MAJOR=12
NEW_MAJOR=18
OLD_BINDIR="/usr/lib/postgresql/${OLD_MAJOR}/bin"
NEW_BINDIR="/usr/lib/postgresql/${NEW_MAJOR}/bin"
DATA_ROOT="/data"
PGDATA="${PGDATA:-/data/postgres}"

# Fresh install: nothing to migrate, let docker-entrypoint.sh initdb normally.
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    exit 0
fi

current_version="$(cat "$PGDATA/PG_VERSION")"

if [ "$current_version" = "$NEW_MAJOR" ]; then
    exit 0
fi

if [ "$current_version" != "$OLD_MAJOR" ]; then
    echo "upgrade.sh: found PostgreSQL $current_version data in $PGDATA. This image only knows how to migrate from $OLD_MAJOR to $NEW_MAJOR." >&2
    echo "upgrade.sh: refusing to start so nothing is touched. Your data has not been modified." >&2
    exit 1
fi

echo "upgrade.sh: found PostgreSQL $current_version data - migrating to $NEW_MAJOR."
echo "upgrade.sh: your existing data is never modified or deleted by this process; it is kept on disk under a backup path when this finishes."

STAMP="$(date +%Y%m%d%H%M%S)"
WORKDIR="$DATA_ROOT/pg_upgrade_work_${STAMP}"
NEW_DATA="$DATA_ROOT/postgres_${NEW_MAJOR}_new"
BACKUP_DATA="$DATA_ROOT/postgres_${OLD_MAJOR}_backup_${STAMP}"

rm -rf "$NEW_DATA" "$WORKDIR"
mkdir -p "$WORKDIR" "$NEW_DATA"

# Determine the exact locale/encoding the existing cluster was created with
# so the freshly-initialized new cluster matches (pg_upgrade requires this).
# Trapped so a failure here still stops the temporary old-version server
# instead of leaving it running or its lock file stale.
stop_old_server() {
    "$OLD_BINDIR/pg_ctl" -D "$PGDATA" -m fast -w stop || true
}

# Unix socket directories default to the current directory, which may sit
# on a bind-mounted /data volume that doesn't support Unix sockets on every
# host; /tmp is always local to the container's own writable layer.
echo "upgrade.sh: reading locale/encoding from existing cluster..."
"$OLD_BINDIR/pg_ctl" -D "$PGDATA" -o "-c listen_addresses='' -c unix_socket_directories='/tmp' -p 5433" -w start -l "$WORKDIR/old_server.log"
trap stop_old_server EXIT

read -r OLD_COLLATE OLD_CTYPE OLD_ENCODING < <(
    "$NEW_BINDIR/psql" -h /tmp -p 5433 -U "$POSTGRES_USER" -d postgres -tAc \
        "SELECT datcollate || ' ' || datctype || ' ' || pg_encoding_to_char(encoding) FROM pg_database WHERE datname='template0';"
)

stop_old_server
trap - EXIT

# initdb in PostgreSQL 18+ defaults to enabling data checksums; pg_upgrade
# requires the old and new clusters to agree, so match whatever the
# existing cluster was created with (this addon's older versions did not
# enable them).
CHECKSUM_ARGS=()
if "$OLD_BINDIR/pg_controldata" "$PGDATA" | grep -q 'Data page checksum version:[[:space:]]*0'; then
    CHECKSUM_ARGS=(--no-data-checksums)
fi

echo "upgrade.sh: initializing new PostgreSQL $NEW_MAJOR data directory (locale=$OLD_COLLATE encoding=$OLD_ENCODING)..."
"$NEW_BINDIR/initdb" \
    --pgdata="$NEW_DATA" \
    --username="$POSTGRES_USER" \
    --pwfile=<(echo "$POSTGRES_PASSWORD") \
    --locale="$OLD_COLLATE" \
    --encoding="$OLD_ENCODING" \
    "${CHECKSUM_ARGS[@]}" \
    >"$WORKDIR/initdb.log" 2>&1

echo "upgrade.sh: running pg_upgrade (old data directory is only read, never modified)..."
cd "$WORKDIR"
"$NEW_BINDIR/pg_upgrade" \
    --old-bindir="$OLD_BINDIR" \
    --new-bindir="$NEW_BINDIR" \
    --old-datadir="$PGDATA" \
    --new-datadir="$NEW_DATA" \
    --username="$POSTGRES_USER" \
    --socketdir=/tmp

# Non-destructive: move the old cluster aside rather than deleting it, then
# swap the freshly-upgraded cluster into the normal PGDATA path.
mv "$PGDATA" "$BACKUP_DATA"
mv "$NEW_DATA" "$PGDATA"

if [ -f "$WORKDIR/analyze_new_cluster.sh" ]; then
    echo "upgrade.sh: refreshing planner statistics on the new cluster..."
    PGDATA="$PGDATA" bash "$WORKDIR/analyze_new_cluster.sh" || true
fi

echo "upgrade.sh: migration to PostgreSQL $NEW_MAJOR complete."
echo "upgrade.sh: your original PostgreSQL $OLD_MAJOR data has been preserved, untouched, at: $BACKUP_DATA"
echo "upgrade.sh: it is NOT deleted automatically. Once you've confirmed everything looks correct, remove it yourself to reclaim disk space."
