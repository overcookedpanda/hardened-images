# hardened-airflow

Apache Airflow 2.x, built on the official `slim` image with its attack
surface cut down, and rebuilt nightly so Debian's security fixes land
without anyone touching the Dockerfile. It contains Airflow itself and
nothing else: no DAGs, connections or deployment-specific packages.

```bash
docker pull ghcr.io/overcookedpanda/hardened-airflow:2.11.2
```

Built, smoke-tested, scanned and published by
[`.github/workflows/airflow.yml`](../../.github/workflows/airflow.yml) through
the shared [build-scan-publish workflow](../../docs/pipeline.md). The gate
fails the build on any fixable CRITICAL, HIGH or MEDIUM finding in Debian
packages, and on any fixable CRITICAL in Python packages (Airflow's
constraints file pins some dependencies below their fixes for the whole 2.11
line; the full list is in each run's report). Tags: `sha-<12>`,
`<YYYYMMDD>` for nightly rebuilds, `2.11.2` for the release it tracks, and
`latest`.

## What's different from `apache/airflow:slim-2.11.2-python3.11`

| | |
|---|---|
| Debian packages | `apt-get full-upgrade` on every build, failing the build if any repository can't be read (plain `upgrade` holds back fixes that change dependencies) |
| sudo | removed (the airflow user was never a sudoer, so it was only a setuid binary) |
| setuid/setgid | every setuid and setgid bit stripped (`su`, `mount`, `passwd`, `ksu`, `ssh-keysign`, ...) |
| docker CLI | removed, with Docker's apt repo |
| SQL Server ODBC driver | removed, with Microsoft's apt repo: its updates need Microsoft's EULA accepted |
| uv | uninstalled; pip is the installer, as Airflow falls back to it anyway |
| Kubernetes provider | kept out, and the build fails if an extra pulls it in: while installed it adds roughly 90 MB to every Airflow process |
| Python packages | `postgres` and `statsd` extras added (the slim image can't reach a Postgres metadata database), all pinned to Airflow's constraints, plus security pins for PyJWT, anyio and certifi above the constraints |
| Constraints | `/opt/hardened-airflow/constraints.txt` pins what the image has, for derived images (see below) |
| User | `airflow` (uid 50000, gid 0), as upstream; an arbitrary uid with gid 0 still works |

The entrypoint, `AIRFLOW_HOME` (`/opt/airflow`) and every `AIRFLOW__*` and
`_AIRFLOW_*` variable behave exactly as in the official image, so the
[official docker-compose file](https://airflow.apache.org/docs/apache-airflow/2.11.2/howto/docker-compose/index.html)
works with only `image:` changed.

Accepted scan findings, each with its reason and when it goes away, are in
[`.trivyignore`](.trivyignore).

`curl` stays: the official compose file's health checks use it.

Why not a Docker Hardened Image: DHI ships Airflow 3 only, and Airflow 3
changes the DAG and REST APIs, so moving to it is a migration rather than a
base swap.

## Usage

A minimal LocalExecutor setup with a Postgres metadata database:

```yaml
x-airflow: &airflow
  image: ghcr.io/overcookedpanda/hardened-airflow:2.11.2
  security_opt: [ "no-new-privileges:true" ]
  environment:
    AIRFLOW__CORE__EXECUTOR: LocalExecutor
    AIRFLOW__DATABASE__SQL_ALCHEMY_CONN: postgresql+psycopg2://airflow:change-me@postgres/airflow
    AIRFLOW__CORE__FERNET_KEY: change-me   # see below
    AIRFLOW__WEBSERVER__SECRET_KEY: change-me-too
    AIRFLOW__CORE__LOAD_EXAMPLES: "false"
  volumes:
    - ./dags:/opt/airflow/dags:ro
    - airflow-logs:/opt/airflow/logs

services:
  postgres:
    image: postgres:17-alpine
    environment:
      POSTGRES_USER: airflow
      POSTGRES_PASSWORD: change-me
      POSTGRES_DB: airflow
    volumes:
      - pg-data:/var/lib/postgresql/data

  # Migrates the database and creates the admin user, and fails if either
  # fails. (The entrypoint's _AIRFLOW_DB_MIGRATE and _AIRFLOW_WWW_USER_CREATE
  # ignore errors, so a broken migration would still let the other services
  # start.) Safe to rerun: creating a user that exists is a no-op.
  airflow-init:
    <<: *airflow
    command:
      - bash
      - -euc
      - |
        airflow db migrate
        airflow users create --role Admin --username admin \
          --password change-me-three --firstname Admin --lastname User \
          --email admin@example.com
    depends_on: [ postgres ]

  webserver:
    <<: *airflow
    command: webserver
    ports: [ "8080:8080" ]
    healthcheck:
      test: [ "CMD", "curl", "--fail", "http://localhost:8080/health" ]
      interval: 30s
    depends_on:
      airflow-init: { condition: service_completed_successfully }

  scheduler:
    <<: *airflow
    command: scheduler
    depends_on:
      airflow-init: { condition: service_completed_successfully }

volumes:
  pg-data:
  airflow-logs:
```

Generate a Fernet key with
`docker run --rm --entrypoint python ghcr.io/overcookedpanda/hardened-airflow:2.11.2 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"`,
and keep it and the passwords out of the compose file in practice (an
`.env` file or Docker secrets).

The `dags` and `logs` directories must be readable (logs: writable) by uid
50000 or gid 0.

## Adding your own DAGs, providers and packages

DAGs need nothing in the image: mount them at `/opt/airflow/dags` as above.

Providers and Python packages go in a derived image, installed as the
`airflow` user against the constraints file the image ships at
`/opt/hardened-airflow/constraints.txt`:

```dockerfile
FROM ghcr.io/overcookedpanda/hardened-airflow:2.11.2

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt \
      --constraint /opt/hardened-airflow/constraints.txt \
    && pip check
```

with, for example:

```text
apache-airflow-providers-slack
pymysql
```

That file is Airflow's constraints for this release with every package in
the image pinned to the version the image has, Airflow itself included. Use
it rather than the upstream constraints URL: the upstream file would
downgrade the security pins listed above. A package it doesn't list gets
its latest compatible version, and `pip check` catches a conflict.

Need a Debian package? Switch to `USER root` for the `apt-get install`, then
back to `USER airflow`. Avoid adding back what this image removed (sudo, the
docker CLI) unless you need it.

Don't install `apache-airflow-providers-cncf-kubernetes` unless you run the
KubernetesExecutor or KubernetesPodOperator: see the table above for its
memory cost.

## Building

```bash
docker build -t hardened-airflow:dev images/airflow
IMAGE=hardened-airflow:dev images/airflow/smoke-test.sh
```

The smoke test checks the hardening above, imports the added packages, starts
the image as an arbitrary uid, parses and runs a Bash and Python DAG, migrates
a real Postgres metadata database, brings up the webserver and scheduler
until `/health` reports both healthy, and checks that `docker stop` shuts
them down on SIGTERM.

## Bumping versions

- **Debian packages**: nothing to do; the nightly rebuild picks them up and
  publishes only when the package set changed.
- **Airflow 2.x patch and minor releases**: Dependabot (docker), weekly, opens
  the PR with the new `FROM` line. The constraints URL follows the base
  image's `AIRFLOW_VERSION`, so the Dockerfile needs nothing else. In the same
  PR, change the version everywhere else it appears: the `extra-tags` value in
  `.github/workflows/airflow.yml`, and the pull, Compose, derived-image and
  docs-link examples in this README and the root README
  (`grep -rn 2.11.2 README.md images/airflow .github/workflows/airflow.yml`
  finds them). Review the security pins and `.trivyignore`; drop a pin once
  the constraints reach its floor.
- **Security pins (PyJWT, anyio, certifi)**: exact versions, so no update
  arrives on its own. Move a pin up when a newer release fixes something, and
  keep it at or above the floor named in the Dockerfile.
- **Airflow 3**: a separate image. Dependabot ignores major bumps.
