# Hardened Apache Airflow 2.x
#
# The official `slim` image with its attack surface cut down and its packages
# patched on every build. Nothing in it is specific to one deployment: no DAGs,
# no connections, no extra drivers. Add yours in a derived image (see README).
#
# Why not a Docker Hardened Image: DHI ships Airflow 3 only, and Airflow 3
# changes the DAG and REST APIs, so moving to it is a migration rather than a
# base swap. This hardens the official 2.x image instead.
#
# Why `slim`: the full image preinstalls ~80 providers and a Java/Docker/uv
# toolchain, which carry most of its fixable CRITICAL findings. Add only the
# providers you use.
FROM apache/airflow:slim-2.11.2-python3.11

LABEL org.opencontainers.image.title="hardened-airflow" \
      org.opencontainers.image.description="Apache Airflow 2.x slim, patched on every build, no sudo, docker CLI, uv or setuid binaries, Postgres and StatsD support" \
      org.opencontainers.image.source="https://github.com/overcookedpanda/hardened-images" \
      org.opencontainers.image.licenses="Apache-2.0"

USER root

# Debian packages.
#
# * The SQL Server ODBC driver (msodbcsql18) and its Microsoft apt repo go:
#   upgrading that package needs Microsoft's EULA accepted, so a patched build
#   can't keep it. Add it back in a derived image if you use SQL Server.
# * The docker CLI (docker-ce-cli, a static Go binary with its own CVEs) and
#   its apt repo go: a task that needs Docker should use the Docker provider
#   against a daemon socket, not a CLI baked into every Airflow process.
# * sudo goes: the airflow user isn't a sudoer, so it is only a setuid binary.
#   Its prerm refuses removal while root has no password unless
#   SUDO_FORCE_REMOVE=yes is set.
# * full-upgrade, not upgrade: plain `upgrade` holds back a fix that changes
#   dependencies, and the base layer lags Debian's security updates.
# * `--error-on=any`: by default a repository that fails to download is only a
#   warning, and the build quietly upgrades nothing.
#
# The base image's SHELL sets pipefail, so `|| true` keeps "nothing matched"
# from failing the build.
RUN { dpkg-query -W -f '${Package}\n' 'msodbcsql*' 'mssql-tools*' docker-ce-cli sudo 2>/dev/null || true; } \
        | SUDO_FORCE_REMOVE=yes xargs -r apt-get purge -y && \
    { grep -rlZ -e packages.microsoft.com -e download.docker.com /etc/apt/sources.list.d/ 2>/dev/null || true; } \
        | xargs -0 -r rm -f && \
    rm -f /etc/apt/keyrings/docker.asc && \
    apt-get update --error-on=any && \
    apt-get full-upgrade -y && \
    apt-get autoremove -y --purge && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/*

# No setuid or setgid binaries (su, mount, passwd, ksu, ssh-keysign, ...).
# Nothing in a container needs to gain privileges, and the image runs with
# no-new-privileges just as well.
RUN find / -xdev -perm /6000 -type f -exec chmod a-s {} + && \
    ! find / -xdev -perm /6000 -type f | grep -q .

USER airflow

# Postgres for the metadata database (the slim image has no psycopg2) and
# StatsD for metrics. Pinned to Airflow's constraints for this release, so the
# build can't quietly move Airflow or its dependencies.
RUN PY="$(python -c 'import sys; print("%d.%d" % sys.version_info[:2])')" && \
    curl -fsSL --retry 3 -o /tmp/constraints-upstream.txt \
        "https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PY}.txt" && \
    pip install --no-cache-dir \
        "apache-airflow[statsd,postgres]==${AIRFLOW_VERSION}" \
        --constraint /tmp/constraints-upstream.txt

# Security floors above the constraints, each for a fixable CRITICAL the
# constraint pin would otherwise keep: PyJWT (auth bypass, CVE-2026-102268),
# anyio (TLS spoofing, CVE-2026-63374), certifi (compromised emSign root,
# GHSA-6q48-6c7w-9gw2). All are minor or patch moves inside the ranges Airflow
# and FAB declare; `pip check` fails the build if one stops being compatible.
RUN pip install --no-cache-dir \
        "PyJWT>=2.14.0" "anyio>=4.14.2" "certifi>=2026.10.18" && \
    pip check

# uv ships with the base only to speed up its own build; Airflow falls back to
# pip and virtualenv without it. Uninstalled rather than deleted so no
# dist-info is left for scanners, and its bundled CA store
# (GHSA-hq85-5cpj-mr62) goes with it.
#
# The Kubernetes provider must stay out: while it is installed, `import
# airflow` loads the whole kubernetes client, and every Airflow process (each
# running task has two) pays roughly 90 MB of memory for it. The slim image
# doesn't have it; the check fails the build if an extra pulls it back in.
RUN pip uninstall -y uv && \
    pip check && \
    ! python -c "import airflow.providers.cncf.kubernetes" 2>/dev/null

# Constraints for derived images: Airflow's file with every installed package
# pinned to the version in this image. Installing with the upstream file
# instead would downgrade the security floors above.
COPY merge-constraints.py /tmp/merge-constraints.py
RUN python /tmp/merge-constraints.py /tmp/constraints-upstream.txt > /tmp/constraints.txt

USER root
RUN install -D -m 0644 -o root -g root /tmp/constraints.txt /opt/hardened-airflow/constraints.txt && \
    rm -f /tmp/constraints.txt /tmp/constraints-upstream.txt /tmp/merge-constraints.py
USER airflow

WORKDIR /opt/airflow
