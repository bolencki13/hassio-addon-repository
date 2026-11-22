#!/usr/bin/env bash
# Runs as root on startup, before upgrade.sh. If this addon has no database
# yet and the old PostgreSQL addon (installed from the original
# matt-FFFFFF repository) is installed, copy its data in via a Supervisor
# backup. The old addon's own data is only read, never changed. upgrade.sh
# then migrates the copy to the current PostgreSQL version.
set -Eeo pipefail

DATA_ROOT=/data
PGDATA="${PGDATA:-/data/postgres}"
OPTIONS="$DATA_ROOT/options.json"
STAGING="$DATA_ROOT/import_staging"
# Slug = first 8 hex chars of sha1(lowercased repository URL) + "_" + addon
# slug. 29b65938 is https://github.com/matt-FFFFFF/hassio-addon-repository.
DEFAULT_SOURCE=29b65938_postgres

log() { echo "import.sh: $*"; }
die() { echo "import.sh: $*" >&2; exit 1; }

api() { # method path [json body]
    curl -sS --max-time 3600 -X "$1" \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        ${3:+--data "$3"} \
        "http://supervisor$2"
}

# Leftovers from an interrupted import only ever hold a partial copy.
rm -rf "$STAGING"

if [ -s "$PGDATA/PG_VERSION" ]; then
    exit 0 # already have a database (imported earlier, or created fresh)
fi

SOURCE="$(jq -r '.migrate_from_addon // empty' "$OPTIONS")"
SOURCE="${SOURCE:-$DEFAULT_SOURCE}"

if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
    log "no Supervisor token available; skipping import and starting with an empty database."
    exit 0
fi

info="$(api GET "/addons/$SOURCE/info")" || die "could not reach the Supervisor API: $info"
if [ "$(jq -r '.result' <<<"$info")" != "ok" ]; then
    log "no addon '$SOURCE' is installed ($(jq -r '.message // "unknown"' <<<"$info")); starting with an empty database."
    exit 0
fi

name="$(jq -r '.data.name' <<<"$info")"
state="$(jq -r '.data.state' <<<"$info")"
log "found old addon '$name' ($SOURCE, version $(jq -r '.data.version' <<<"$info"), state: $state)."

# A backup of a running database is not a consistent copy. Stopping another
# addon needs a much broader permission than this addon asks for, and it
# takes the database offline, so leave that decision to you.
if [ "$state" != "stopped" ]; then
    die "the old addon '$name' is still running. Stop it (and Home Assistant's recorder / TeslaMate will lose their database until you switch them over), then start this addon again. Nothing has been changed."
fi

log "asking the Supervisor to back up '$name' (this can take a while for a large database)..."
FILE="postgres-migration-source-$(date +%Y%m%d%H%M%S).tar"
body="$(jq -nc --arg n "PostgreSQL migration source ($SOURCE)" --arg f "$FILE" --arg a "$SOURCE" \
    '{name: $n, filename: $f, addons: [$a], homeassistant: false, folders: [], compressed: true}')"
resp="$(api POST /backups/new/partial "$body")" || die "backup request failed: $resp"
[ "$(jq -r '.result' <<<"$resp")" = "ok" ] || die "backup failed: $(jq -r '.message // .' <<<"$resp")"
log "backup created: '$FILE' (slug $(jq -r '.data.slug' <<<"$resp")). It stays in your Home Assistant backups list as a rollback copy."

ARCHIVE="/backup/$FILE"
[ -f "$ARCHIVE" ] || die "backup file $ARCHIVE not found in /backup. Nothing has been changed."

mkdir -p "$STAGING"

# The backup is a tar holding one archive per addon; find this addon's.
member="$(tar -tf "$ARCHIVE" | grep -E "(^|/)${SOURCE}\.tar(\.gz)?$" | head -n1 || true)"
[ -n "$member" ] || die "backup does not contain an archive for $SOURCE. Contents: $(tar -tf "$ARCHIVE" | tr '\n' ' ')"
tar -xf "$ARCHIVE" -C "$STAGING" "$member"
INNER="$STAGING/$member"
case "$INNER" in *.gz) TARZ=(-z) ;; *) TARZ=() ;; esac

# Locate the database directory by its PG_VERSION file rather than assume a layout.
pgv="$(tar "${TARZ[@]}" -tf "$INNER" | grep -E '(^|/)postgres/PG_VERSION$' | head -n1 || true)"
[ -n "$pgv" ] || die "no PostgreSQL data directory found in the backup of $SOURCE. Nothing has been changed."
src_dir="${pgv%/PG_VERSION}"
opts="${src_dir%postgres}options.json"
tar "${TARZ[@]}" -tf "$INNER" | grep -Fx "$opts" >/dev/null || opts=""

# Check this addon's options match the old one before copying anything big.
if [ -n "$opts" ]; then
    tar "${TARZ[@]}" -xf "$INNER" -C "$STAGING" "$opts"
    old_user="$(jq -r '.user' "$STAGING/$opts")"
    old_db="$(jq -r '.database' "$STAGING/$opts")"
    new_user="$(jq -r '.user' "$OPTIONS")"
    new_db="$(jq -r '.database' "$OPTIONS")"
    if [ "$old_user" != "$new_user" ] || [ "$old_db" != "$new_db" ]; then
        rm -rf "$STAGING"
        die "this addon's options (user '$new_user', database '$new_db') don't match the old addon's (user '$old_user', database '$old_db'). Set them to match, including the password, then start this addon again."
    fi
fi

log "extracting database from backup..."
tar "${TARZ[@]}" -xf "$INNER" -C "$STAGING" --numeric-owner --same-permissions "$src_dir"
rm -f "$INNER"
[ -s "$STAGING/$src_dir/PG_VERSION" ] || die "extraction incomplete. Nothing has been changed; restart to retry."

# Only now move it into place, so an interrupted import is simply retried.
rmdir "$PGDATA" 2>/dev/null || true
[ ! -e "$PGDATA" ] || die "$PGDATA exists but holds no database; refusing to overwrite it. Remove it and restart."
mv "$STAGING/$src_dir" "$PGDATA"
rm -rf "$STAGING"

log "imported PostgreSQL $(cat "$PGDATA/PG_VERSION") data from '$name'. The old addon's own data is unchanged."
log "clients that connect through the host (e.g. homeassistant.local:5432) need no change if this addon publishes the same port the old one did; clients using the old addon's hostname (29b65938-postgres) must switch to this addon's."
