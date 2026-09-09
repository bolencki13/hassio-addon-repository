# Home Assistant PostgreSQL addon

PostgreSQL is a powerful, open source object-relational database system with over 30 years of active development that has earned it a strong reputation for reliability, feature robustness, and performance.

This addon is part of [bolencki13's Home Assistant addon repo](https://github.com/bolencki13/hassio-addon-repository) - see link for instructions on how to add to Home Assistant.

## Version

This addon runs PostgreSQL **18** (the current latest stable major version). It's built locally on your Home Assistant host from a `Dockerfile` (there is no prebuilt image to pull), based on the official [`postgres:18-bookworm`](https://hub.docker.com/_/postgres) Docker image.

Supported architectures: `amd64`, `aarch64`.

## Upgrading from PostgreSQL 12 (this addon's previous version)

If your existing data directory still contains a PostgreSQL 12 database, the addon **automatically migrates it to PostgreSQL 18 the first time it starts** after updating, using [`pg_upgrade`](https://www.postgresql.org/docs/current/pgupgrade.html). This is non-destructive:

* Your original v12 data directory is never modified or deleted. `pg_upgrade` only *reads* it.
* Once the upgrade finishes successfully, the new v18 cluster is moved into place and the original v12 data is kept alongside it at `/data/postgres_12_backup_<timestamp>` as an automatic backup.
* If the upgrade fails for any reason, the addon refuses to start rather than run on a half-migrated database - your original data is untouched and the addon logs will explain what went wrong. Fix the issue and restart the addon to retry; nothing needs to be reset by hand.
* If the addon is killed or the host loses power mid-upgrade, your original v12 data is still safe (it's never renamed or altered until the new cluster is fully built), and simply restarting the addon retries the migration cleanly.

Because `pg_upgrade` copies data files rather than modifying them in place, a large database needs roughly double its size in free disk space during the upgrade, and the first startup after updating may take a while - watch the addon logs to follow progress.

**Nothing is deleted automatically.** Once you've confirmed your data looks correct on PostgreSQL 18, you can manually remove the `postgres_12_backup_*` directory under the addon's `/data` folder (accessible via Samba/SSH addons, or the Supervisor's file editor) to reclaim disk space.

As always, taking your own backup before a major version upgrade is good practice - see [Connecting to the DB](#connecting-to-the-db) below if you want to use `pg_dumpall`/`pgAdmin` for extra peace of mind.

## Configuration

Set the database name, username and password in the yaml editor:

```yml
username: mydbuser
password: mysecretpassword
database: mydbname
```

## Connecting to the DB

To connect your application to the database, specify the server name as: `<addon-hostname>` (find the exact hostname for this addon under its info page in the Supervisor). The port number is the default of 5432.
