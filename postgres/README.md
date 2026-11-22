# Home Assistant PostgreSQL addon

PostgreSQL is a powerful, open source object-relational database system with over 30 years of active development that has earned it a strong reputation for reliability, feature robustness, and performance.

This addon is part of [bolencki13's Home Assistant addon repo](https://github.com/bolencki13/hassio-addon-repository) - see link for instructions on how to add to Home Assistant.

## Version

This addon runs PostgreSQL **18** (the current latest stable major version). It's built locally on your Home Assistant host from a `Dockerfile` (there is no prebuilt image to pull), based on the official [`postgres:18-bookworm`](https://hub.docker.com/_/postgres) Docker image.

Supported architectures: `amd64`, `aarch64`.

## Moving from the original `matt-FFFFFF` PostgreSQL addon

Home Assistant treats an addon from a different repository as a separate addon, with its own data folder and hostname. So installing this one doesn't replace the original; it sits next to it. Its startup handles copying the data over:

1. Take a Home Assistant backup of the old PostgreSQL addon.
2. Add this repository and install this addon. **Don't start it yet.**
3. In its configuration, set `user`, `password` and `database` to the same values as the old addon. If the old addon has a port set under **Network** (e.g. `5432`), set the same port here too - this addon doesn't publish one by default.
4. Stop TeslaMate (and anything else using the database), then **stop the old PostgreSQL addon** and turn off its **Start on boot** setting, so a reboot doesn't bring it back up alongside this one.
5. Start this addon. If it has no database yet and finds the old addon (`29b65938_postgres`) installed and stopped, it asks the Supervisor to back up the old addon, copies the database out of that backup, and then upgrades the copy to PostgreSQL 18 as described below. The old addon's own data is only read; it isn't changed.
6. Watch the log until it shows `migration to PostgreSQL 18 complete`.
7. Check how Home Assistant's recorder `db_url` (usually in `secrets.yaml`) and TeslaMate reach the database, then restart Home Assistant and start TeslaMate:
   * **Through the host** (e.g. `postgresql://user:pass@homeassistant.local/db`, or the host's IP address): nothing to change, as long as this addon publishes the same port the old one did (step 3). The old addon is stopped, so the port now belongs to this one.
   * **Through the old addon's hostname** (`29b65938-postgres`): change it to this addon's hostname. Open this addon in Home Assistant; the browser's address ends in `/hassio/addon/<ID>` (e.g. `b4b4d228_postgres`). The hostname is that ID with the underscore replaced by a hyphen (`b4b4d228-postgres`). Look up your own rather than copying the example; the prefix depends on the exact repository URL you added.

   All databases and logins on the old server come across, including ones you created by hand for Home Assistant, so user, password and database name stay the same either way.
8. Once you're happy, uninstall the old addon - uninstalling deletes its data, so until then it's your instant rollback (stop this addon, turn its Start on boot off, start the old one and turn its Start on boot back on, and undo any hostname change from step 7). The backup the import created (`PostgreSQL migration source (...)`) also stays in your backups list until you delete it.

The addon refuses to start, without touching either addon's data, if the old addon is still running or if the `user`/`database` options don't match the old addon's (in that case the backup has already been made, since that's where the old options are read from; it just stays in your backups list). If the old addon isn't installed, it simply starts with an empty database. If your old addon has a different ID, set the optional `migrate_from_addon` option to it.

For this, the addon has access to the Supervisor's backup functions (`hassio_role: backup`) and read-only access to the backups folder.

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
user: mydbuser
password: mysecretpassword
database: mydbname
```

## Connecting to the DB

To connect your application to the database, specify the server name as: `<addon-hostname>` (find the exact hostname for this addon under its info page in the Supervisor). The port number is the default of 5432.
