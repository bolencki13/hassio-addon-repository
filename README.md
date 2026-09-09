# My Addon Repo

A Home Assistant add-on repository maintained for personal use, containing a single add-on: **PostgreSQL**.

This is a fork of the original `matt-FFFFFF/hassio-addon-repository`, which was archived after its PostgreSQL add-on fell behind (stuck on PostgreSQL 12, while Home Assistant requires PostgreSQL 15+). All other add-ons from the upstream repo have been removed here, and PostgreSQL has been upgraded to the latest stable major version, with an automatic, non-destructive in-place upgrade path from existing 12.x data. See [postgres/README.md](postgres/README.md) for details.

## Adding this repository to Home Assistant

Add `https://github.com/bolencki13/hassio-addon-repository` as an add-on repository in the Home Assistant Supervisor add-on store.
