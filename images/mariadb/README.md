# hardened-mariadb

MariaDB from the official MariaDB apt repository on Ubuntu 24.04, rebuilt
nightly so Ubuntu's security fixes land without anyone touching the
Dockerfile.

```bash
docker pull ghcr.io/overcookedpanda/hardened-mariadb:latest
```

Built, smoke-tested, scanned and published by
[`.github/workflows/mariadb.yml`](../../.github/workflows/mariadb.yml) through
the shared [build-scan-publish workflow](../../docs/pipeline.md). The gate
fails the build on any fixable CRITICAL, HIGH or MEDIUM finding. Tags:
`sha-<12>`, `<YYYYMMDD>` for nightly rebuilds, `12.3` for the series it
tracks, and `latest`.

## What's different from a plain MariaDB image

| | |
|---|---|
| Base | `ubuntu:24.04`, with `apt-get full-upgrade` on every build (plain `upgrade` silently holds back a fix that changes dependencies) |
| MariaDB | the `12.3` series from the official repo, pinned to a series rather than a rolling path, which mirrors drop without notice |
| User | runs as `mysql`, never root |
| setuid/setgid | every setuid and setgid binary removed |
| Build tools | `curl`, `gnupg` and `apt-transport-https` purged after use; docs and man pages removed |
| Health | `HEALTHCHECK` with `mariadb-admin ping` |

## Usage

The entrypoint follows the familiar variables:

| Variable | Effect on first start |
|---|---|
| `MYSQL_ROOT_PASSWORD` | sets the root password, and creates `root@'%'` with it |
| `MYSQL_DATABASE` | creates the database |
| `MYSQL_USER`, `MYSQL_PASSWORD` | creates the user with all privileges on `MYSQL_DATABASE` |

Files in `/docker-entrypoint-initdb.d/` (`*.sh`, `*.sql`, `*.sql.gz`) run once,
on first start.

```yaml
services:
  db:
    image: ghcr.io/overcookedpanda/hardened-mariadb:12.3
    read_only: true
    security_opt: [ "no-new-privileges:true" ]
    tmpfs:
      - /tmp:size=1G,exec
      - /var/run/mysqld:size=100M,uid=999,gid=999   # 999: the image's mysql user
      - /var/tmp:size=500M
    environment:
      MYSQL_ROOT_PASSWORD: change-me
      MYSQL_DATABASE: app
      MYSQL_USER: app
      MYSQL_PASSWORD: change-me-too
    volumes:
      - db-data:/var/lib/mysql
      - ./conf:/etc/mysql/conf.d:ro   # your server.cnf
volumes:
  db-data:
```

The image runs with a read-only root filesystem as long as `/var/lib/mysql`
is a volume and `/tmp`, `/var/tmp` and `/var/run/mysqld` are writable. Check
the mysql uid with `docker run --rm --entrypoint id <image> mysql` if you
build your own.

[`examples/server-64gb.cnf`](examples/server-64gb.cnf) is a tuning example
for a dedicated 64 GB host (48 GB buffer pool). Scale
`innodb_buffer_pool_size` and the thread counts to your machine before using
it; the image itself ships MariaDB's defaults.

## Building

```bash
docker build -t hardened-mariadb:dev images/mariadb
IMAGE=hardened-mariadb:dev images/mariadb/smoke-test.sh
```

Build arguments:

- `MARIADB_SERIES` (default `12.3`): which MariaDB series to install.
- `MARIADB_MIRROR`: the apt mirror. Any mirror from
  [mariadb.org/download](https://mariadb.org/download/) (repositories tab)
  works.

## Bumping versions

- **Ubuntu packages**: nothing to do; the nightly rebuild picks them up and
  publishes only when the package set changed.
- **Ubuntu base**: Dependabot (docker), weekly.
- **MariaDB series**: change `MARIADB_SERIES`, and the `extra-tags` value in
  `.github/workflows/mariadb.yml`. A new major version is a database upgrade,
  so read MariaDB's upgrade notes before moving an existing data directory.
