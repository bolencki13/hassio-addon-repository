# Home Assistant PostgreSQL addon

PostgreSQL is a powerful, open source object-relational database system with over 30 years of active development that has earned it a strong reputation for reliability, feature robustness, and performance.

This addon is part of [bolencki13's Home Assistant addon repo](https://github.com/bolencki13/hassio-addon-repository) - see link for instructions on how to add to Home Assistant.

## Version

This addon runs PostgreSQL **18** (the current latest stable major version). It's built locally on your Home Assistant host from a `Dockerfile` (there is no prebuilt image to pull), based on the official [`postgres:18-bookworm`](https://hub.docker.com/_/postgres) Docker image.

Supported architectures: `amd64`, `aarch64`.

## Upgrading from PostgreSQL 12 (this addon's previous version)

If your existing data directory still contains a PostgreSQL 12 database, the addon **automatically migrates it to PostgreSQL 18 the first time it starts** after updating, using [`pg_upgrade`](https://www.postgresql.org/docs/current/pgupgrade.html). Your data is never changed or deleted:

* `pg_upgrade` copies your data into a new v18 cluster. The original v12 data directory stays in place and is kept afterwards at `/data/postgres_12_backup_<timestamp>` as an automatic backup.
* Two small, harmless changes are made to the original cluster: PostgreSQL's own housekeeping files are updated when it's briefly started to read its settings, and if the `earthdistance` extension (used by TeslaMate) is installed, its functions get a fixed `search_path`. Without the latter, indexes built on `ll_to_earth(...)` can't be restored. Neither affects your data, and the original still works with the previous addon version.
* Before switching over, every index is rebuilt. Previous versions of this addon ran on Alpine Linux, which sorts text differently from the Debian base used now, so indexes on text columns copied as-is would silently return wrong results. Extensions are updated and planner statistics refreshed in the same step.
* If anything fails, including not enough free disk space, the addon refuses to start rather than run on a half-migrated database. The original data is still in place and the addon logs explain what went wrong. Fix the issue and restart the addon to retry; nothing needs to be reset by hand.
* If the addon is killed or the host loses power mid-upgrade, the original data is still in place (it isn't moved until the new cluster is fully built), and restarting the addon retries the migration cleanly.

The upgrade needs about 1.5x the database size (plus 512 MB) in free disk space, and the first start after updating can take a long time on a large database (copying plus rebuilding every index) - watch the addon logs. When they show `migration to PostgreSQL 18 complete`, **restart Home Assistant** (and TeslaMate or anything else using this database) so they reconnect.

**Nothing is deleted automatically.** Once you've confirmed your data looks correct on PostgreSQL 18, remove the `postgres_12_backup_*` directory from the addon's `/data` folder to reclaim disk space, e.g. from a host shell: `docker exec <addon container> rm -rf /data/postgres_12_backup_<timestamp>`.

Take a Home Assistant backup of this addon before updating. It's your rollback copy if anything goes wrong.

## Configuration

Set the database name, username and password in the yaml editor:

```yml
username: mydbuser
password: mysecretpassword
database: mydbname
```

## Connecting to the DB

To connect your application to the database, specify the server name as: `<addon-hostname>` (find the exact hostname for this addon under its info page in the Supervisor). The port number is the default of 5432.
