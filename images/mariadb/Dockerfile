# Use Ubuntu 24.04 LTS (Noble)
FROM ubuntu:24.04

# Which MariaDB series to track, and which mirror to install it from. Any
# mirror listed at https://mariadb.org/download/ (repositories tab) works.
ARG MARIADB_SERIES=12.3
ARG MARIADB_MIRROR=https://mirrors.accretive-networks.net/mariadb/repo

LABEL org.opencontainers.image.title="hardened-mariadb" \
      org.opencontainers.image.description="MariaDB from the official apt repo on Ubuntu 24.04, patched on every build, non-root, setuid binaries removed" \
      org.opencontainers.image.source="https://github.com/overcookedpanda/hardened-images" \
      org.opencontainers.image.licenses="GPL-2.0-only"

# Security: Create non-root user first
RUN groupadd -r mysql && useradd -r -g mysql mysql

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg

RUN mkdir -p /etc/apt/keyrings && \
    # Import MariaDB repository key
    curl -o /etc/apt/keyrings/mariadb-keyring.pgp 'https://mariadb.org/mariadb_release_signing_key.pgp' && \
    # Add the MariaDB repository for one series. Pin a series (12.3), not a
    # rolling path: mirrors drop old rolling paths without notice, and a
    # series pin never jumps a major version on you.
    echo "# MariaDB ${MARIADB_SERIES} repository list - created $(date -u +'%Y-%m-%d %H:%M') UTC" > /etc/apt/sources.list.d/mariadb.list && \
    echo "# https://mariadb.org/download/" >> /etc/apt/sources.list.d/mariadb.list && \
    echo "deb [signed-by=/etc/apt/keyrings/mariadb-keyring.pgp] ${MARIADB_MIRROR}/${MARIADB_SERIES}/ubuntu noble main" >> /etc/apt/sources.list.d/mariadb.list && \
    # Update package lists with new repository
    apt-get update && \
    # Security: apply available patches to the Ubuntu base packages. Without
    # this the image ships whatever versions shipped in the base layer, which
    # lag behind Ubuntu's security updates.
    #
    # full-upgrade rather than upgrade: plain `upgrade` refuses to add or remove
    # packages, so a security fix that changes dependencies is silently held
    # back. Only ~30 base packages are installed at this point (MariaDB is
    # installed below), so the removal risk full-upgrade carries is minimal.
    apt-get full-upgrade -y && \
    # Install MariaDB
    apt-get install -y --no-install-recommends \
        mariadb-server \
        mariadb-client \
        mariadb-backup \
        gosu \
        pwgen \
        tzdata

RUN echo "=== Installed MariaDB version ===" && \
    mariadb --version && \
    mariadbd --version

RUN apt-get purge -y apt-transport-https curl gnupg && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/* && \
    rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*

# Create necessary directories with proper permissions
RUN mkdir -p /var/lib/mysql /var/run/mysqld /docker-entrypoint-initdb.d && \
    chown -R mysql:mysql /var/lib/mysql /var/run/mysqld && \
    chmod 1777 /tmp

# Copy custom entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Security: Remove setuid/setgid binaries to reduce attack surface
RUN find /usr/bin /usr/sbin /bin /sbin -perm /6000 -type f -delete || true

# Security: Switch to non-root user for runtime
USER mysql

# Expose port
EXPOSE 3306

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s --retries=3 \
    CMD mariadb-admin ping -h localhost --silent || exit 1

# Use custom entrypoint
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["mariadbd"]
