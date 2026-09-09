# Changelog

## 2.0.0

**MAJOR VERSION UPGRADE - PostgreSQL 12 -> 18**

This addon is now built locally from a Dockerfile (based on `postgres:18-bookworm`) instead of pulling a prebuilt image, and only supports `amd64`/`aarch64` (armhf/armv7 dropped - no current official PostgreSQL images support them).

If your data directory still contains a PostgreSQL 12 database, the addon automatically upgrades it to PostgreSQL 18 in place on first start using `pg_upgrade`. This is non-destructive: your original v12 data is only ever read, never modified, and is kept on disk as an automatic backup (`postgres_12_backup_<timestamp>`) once the upgrade completes. See [README.md](README.md#upgrading-from-postgresql-12-this-addons-previous-version) for full details, failure handling, and how to reclaim disk space afterwards once you've verified the upgrade.

Changes:

* Postgres 18
* Automatic, non-destructive `pg_upgrade` migration from existing v12 data
* Addon is now built locally (no external image dependency)
* Dropped armhf/armv7 support

## 1.0.0

**BREAKING CHANGE**

YOU MUST BACKUP YOU DATA BEFORE UPDATING

YOU MUST RESTORE YOUR DATA AFTER UPDATING

1. Stop any connections to the database, e.g. stop the TeslaMate addon
2. Expose your postgres instance to the local network using the network options in the addon configuration. Use port 5432.
3. Use pgAdmin to create a backup
4. Update the addon
5. Restore your data using pgAdmin
6. Disable the external network connection in teh addin configuration
7. Re-start TeslaMate

Changes:

* Use /data for persistent storage
* Postgres 12.5

[Full Changelog](CHANGELOG-FULL.md)
