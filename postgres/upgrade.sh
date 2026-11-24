#!/usr/bin/env bash
set -Eeo pipefail

OLD_MAJOR=12
NEW_MAJOR=18
OLD_BINDIR="/usr/lib/postgresql/${OLD_MAJOR}/bin"
NEW_BINDIR="/usr/lib/postgresql/${NEW_MAJOR}/bin"
DATA_ROOT="/data"
PGDATA="${PGDATA:-/data/postgres}"
# Unix socket directories default to the current directory, which may sit
# on a bind-mounted /data volume that doesn't support Unix sockets on every
# host; /tmp is always local to the container's own writable layer.
SOCKDIR=/tmp
TMP_PORT=5433

# Present once the configured user's password has been checked for the old
# md5 format (see convert_password); the check then never runs again.
PASSWORD_MARKER="$DATA_ROOT/.password_format_checked"
SERVER_LOG=/tmp/temp_server.log

log() { echo "upgrade.sh: $*"; }
die() { echo "upgrade.sh: $*" >&2; exit 1; }

start_server() { # bindir datadir
    "$1/pg_ctl" -D "$2" -w start -l "$SERVER_LOG" \
        -o "-c listen_addresses='' -c unix_socket_directories='$SOCKDIR' -p $TMP_PORT"
}
stop_server() { # bindir datadir
    "$1/pg_ctl" -D "$2" -m fast -w stop || true
}

# PostgreSQL 12 stored passwords as md5 hashes, a format PostgreSQL 18
# deprecates. The configured user's password is known (it's in this addon's
# options), so store it again in the current SCRAM format. Only done when
# the configured password matches the stored hash: re-setting it to a
# different value would lock out clients using the real one. Needs a
# temporary server running; connects as $1. Never fails the startup; returns
# 0 once the password is in the current format, so the check can stop.
convert_password() { # connect-as user
    local result
    result="$(ADDON_USER="$POSTGRES_USER" ADDON_PW="$POSTGRES_PASSWORD" \
        "$NEW_BINDIR/psql" -X -q -tA -h "$SOCKDIR" -p "$TMP_PORT" -U "$1" -d postgres -v ON_ERROR_STOP=1 2>&1 <<'SQL'
\getenv u ADDON_USER
\getenv pw ADDON_PW
SELECT coalesce(bool_or(rolpassword LIKE 'md5%'), false) AS is_md5,
       coalesce(bool_or(rolpassword = 'md5' || md5(:'pw' || :'u')), false) AS matches
FROM pg_authid WHERE rolname = :'u' \gset
\if :matches
SET password_encryption = 'scram-sha-256';
ALTER ROLE :"u" PASSWORD :'pw';
\echo converted
\elif :is_md5
\echo mismatch
\else
\echo current
\endif
SQL
)" || { log "could not check the password format ($result); leaving it as it is."; return 1; }
    case "$result" in
        converted) log "re-stored the password of user '$POSTGRES_USER' in the current SCRAM format (same password; clients need no change)." ;;
        mismatch)  log "user '$POSTGRES_USER' still has an md5 password, but it doesn't match the password in this addon's options, so it was left alone. Set the correct password in the options and restart to convert it."; return 1 ;;
        *)         log "password format of user '$POSTGRES_USER' is already current." ;;
    esac
}

# Fresh install: nothing to migrate, let docker-entrypoint.sh initdb normally.
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    exit 0
fi

current_version="$(cat "$PGDATA/PG_VERSION")"

if [ "$current_version" = "$NEW_MAJOR" ]; then
    # Clusters migrated before the password conversion existed get it once.
    if [ ! -e "$PASSWORD_MARKER" ]; then
        log "checking the password format of user '$POSTGRES_USER'..."
        if start_server "$NEW_BINDIR" "$PGDATA" >/dev/null; then
            trap 'stop_server "$NEW_BINDIR" "$PGDATA"' EXIT
            PASSWORD_DONE=0; convert_password "$POSTGRES_USER" || PASSWORD_DONE=1
            stop_server "$NEW_BINDIR" "$PGDATA" >/dev/null
            trap - EXIT
            [ "$PASSWORD_DONE" -ne 0 ] || touch "$PASSWORD_MARKER"
        else
            log "could not start a temporary server to check the password format; skipping (see $SERVER_LOG)."
        fi
    fi
    exit 0
fi

if [ "$current_version" != "$OLD_MAJOR" ]; then
    die "found PostgreSQL $current_version data in $PGDATA, but this image only migrates $OLD_MAJOR -> $NEW_MAJOR. Refusing to start; your data has not been modified."
fi

log "found PostgreSQL $current_version data - migrating to $NEW_MAJOR."
log "your data is never changed or deleted by this process; the original data directory is kept on disk as a backup when this finishes."

STAMP="$(date +%Y%m%d%H%M%S)"
WORKDIR="$DATA_ROOT/pg_upgrade_work_${STAMP}"
NEW_DATA="$DATA_ROOT/postgres_${NEW_MAJOR}_new"
BACKUP_DATA="$DATA_ROOT/postgres_${OLD_MAJOR}_backup_${STAMP}"

# Clear leftovers from an earlier interrupted attempt. These only ever hold
# the half-built new cluster; the original data lives in $PGDATA.
rm -rf "$NEW_DATA" "$DATA_ROOT"/pg_upgrade_work_*

# pg_upgrade copies every data file and the reindex below rebuilds every
# index, so the new cluster needs roughly as much space again as the old
# one, plus headroom. Fail early with a clear message rather than partway.
DATA_KB="$(du -sk "$PGDATA" | cut -f1)"
FREE_KB="$(df -Pk "$DATA_ROOT" | awk 'NR==2 {print $4}')"
NEED_KB=$(( DATA_KB * 3 / 2 + 512 * 1024 ))
if [ "$FREE_KB" -lt "$NEED_KB" ]; then
    die "not enough free disk space to upgrade: database is $((DATA_KB / 1024)) MB, need about $((NEED_KB / 1024)) MB free, have $((FREE_KB / 1024)) MB. Free up space and restart the addon. Your data has not been modified."
fi

mkdir -p "$WORKDIR" "$NEW_DATA"
SERVER_LOG="$WORKDIR/temp_server.log"

sql() { # db, query
    "$NEW_BINDIR/psql" -h "$SOCKDIR" -p "$TMP_PORT" -U "$INSTALL_USER" -d "$1" -v ON_ERROR_STOP=1 -tAc "$2"
}

# Read what the existing cluster was created with, so the new cluster
# matches (pg_upgrade requires the same locale, encoding and install user).
# Trapped so a failure still stops the temporary server.
log "reading settings from existing cluster..."
start_server "$OLD_BINDIR" "$PGDATA"
trap 'stop_server "$OLD_BINDIR" "$PGDATA"' EXIT
INSTALL_USER="$POSTGRES_USER"
INSTALL_USER="$(sql postgres "SELECT rolname FROM pg_authid WHERE oid = 10")"
read -r OLD_COLLATE OLD_CTYPE OLD_ENCODING < <(
    sql postgres "SELECT datcollate || ' ' || datctype || ' ' || pg_encoding_to_char(encoding) FROM pg_database WHERE datname = 'template0'"
)

# The earthdistance extension (used by TeslaMate) ships SQL functions such
# as ll_to_earth() that reference the "earth" type without a schema. During
# pg_upgrade the schema is restored with an empty search_path, so any index
# built on ll_to_earth(...) fails to restore. Pinning a search_path on those
# functions is the standard fix. It must be done here, on the old cluster,
# because pg_upgrade copies function definitions from it. This changes a
# function setting only - no data - and works the same on PostgreSQL 12.
while read -r db; do
    [ -n "$db" ] || continue
    sql "$db" "
        DO \$\$
        DECLARE f regprocedure; path text;
        BEGIN
            SELECT string_agg(DISTINCT quote_ident(n.nspname), ', ') INTO path
            FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
            WHERE e.extname IN ('earthdistance', 'cube');
            FOR f IN
                SELECT p.oid::regprocedure
                FROM pg_extension e
                JOIN pg_depend d ON d.refobjid = e.oid AND d.deptype = 'e' AND d.classid = 'pg_proc'::regclass
                JOIN pg_proc p ON p.oid = d.objid
                JOIN pg_language l ON l.oid = p.prolang AND l.lanname = 'sql'
                WHERE e.extname = 'earthdistance' AND p.proconfig IS NULL
            LOOP
                RAISE NOTICE 'setting search_path on %', f;
                EXECUTE format('ALTER FUNCTION %s SET search_path = %s, pg_temp', f, path);
            END LOOP;
        END \$\$" 2>&1 | sed "s/^/upgrade.sh: [$db] /"
done < <(sql postgres "SELECT datname FROM pg_database WHERE datallowconn")

stop_server "$OLD_BINDIR" "$PGDATA"
trap - EXIT

# initdb in PostgreSQL 18+ enables data checksums by default; pg_upgrade
# requires both clusters to agree, so match the existing one.
CHECKSUM_ARGS=()
if "$OLD_BINDIR/pg_controldata" "$PGDATA" | grep -q 'Data page checksum version:[[:space:]]*0'; then
    CHECKSUM_ARGS=(--no-data-checksums)
fi

log "initializing new PostgreSQL $NEW_MAJOR data directory (user=$INSTALL_USER locale=$OLD_COLLATE encoding=$OLD_ENCODING)..."
"$NEW_BINDIR/initdb" \
    --pgdata="$NEW_DATA" \
    --username="$INSTALL_USER" \
    --pwfile=<(echo "$POSTGRES_PASSWORD") \
    --locale="$OLD_COLLATE" \
    --encoding="$OLD_ENCODING" \
    "${CHECKSUM_ARGS[@]}" \
    >"$WORKDIR/initdb.log" 2>&1

log "running pg_upgrade (copies your data into the new cluster; the original files stay in place)..."
cd "$WORKDIR"
"$NEW_BINDIR/pg_upgrade" \
    --old-bindir="$OLD_BINDIR" \
    --new-bindir="$NEW_BINDIR" \
    --old-datadir="$PGDATA" \
    --new-datadir="$NEW_DATA" \
    --username="$INSTALL_USER" \
    --socketdir="$SOCKDIR"

# pg_upgrade does not carry over pg_hba.conf. The old one has the rule that
# lets Home Assistant / TeslaMate connect over the network, using md5 auth,
# which matches how the existing passwords are stored (PG12 hashed them as
# md5; a scram-only rule would reject them).
cp "$PGDATA/pg_hba.conf" "$NEW_DATA/pg_hba.conf"

# Finish the new cluster before it replaces the old one, so a failure here
# leaves the original data in place and the next start simply retries.
log "finishing new cluster..."
start_server "$NEW_BINDIR" "$NEW_DATA"
trap 'stop_server "$NEW_BINDIR" "$NEW_DATA"' EXIT

# Older versions of this addon ran on Alpine (musl), which sorts text by
# raw byte value even when the locale is en_US.utf8. This image runs on
# Debian (glibc), which sorts linguistically. pg_upgrade copies index files
# as-is, so every index on a text column would be out of order - lookups
# silently miss rows and unique constraints stop working. Rebuild them all.
log "rebuilding indexes for the new collation library (can take a while on large databases)..."
"$NEW_BINDIR/reindexdb" -h "$SOCKDIR" -p "$TMP_PORT" -U "$INSTALL_USER" --all

if [ -f "$WORKDIR/update_extensions.sql" ]; then
    log "updating extensions..."
    "$NEW_BINDIR/psql" -h "$SOCKDIR" -p "$TMP_PORT" -U "$INSTALL_USER" -d postgres \
        -v ON_ERROR_STOP=1 -f "$WORKDIR/update_extensions.sql"
fi

log "refreshing planner statistics..."
"$NEW_BINDIR/vacuumdb" -h "$SOCKDIR" -p "$TMP_PORT" -U "$INSTALL_USER" \
    --all --analyze-in-stages --missing-stats-only

PASSWORD_DONE=0; convert_password "$INSTALL_USER" || PASSWORD_DONE=1

stop_server "$NEW_BINDIR" "$NEW_DATA"
trap - EXIT

# Non-destructive: move the old cluster aside rather than deleting it, then
# swap the finished cluster into the normal PGDATA path.
mv "$PGDATA" "$BACKUP_DATA"
mv "$NEW_DATA" "$PGDATA"
[ "$PASSWORD_DONE" -ne 0 ] || touch "$PASSWORD_MARKER"

log "migration to PostgreSQL $NEW_MAJOR complete."
log "your original PostgreSQL $OLD_MAJOR data directory has been kept as a backup at: $BACKUP_DATA"
log "it is NOT deleted automatically. Once you've confirmed everything looks correct, remove it yourself to reclaim disk space."
log "restart Home Assistant (and anything else using this database) so they reconnect."
