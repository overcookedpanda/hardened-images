#!/bin/bash
set -eo pipefail

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# MariaDB 12.0 uses these specific binaries
MYSQLD_BIN="mariadbd"
MYSQLADMIN_BIN="mariadb-admin"
MYSQL_BIN="mariadb"
MYSQL_INSTALL_BIN="mariadb-install-db"

log "Using MariaDB 12.0 binaries:"
log "  Server: $MYSQLD_BIN"
log "  Admin: $MYSQLADMIN_BIN"
log "  Client: $MYSQL_BIN"
log "  Install: $MYSQL_INSTALL_BIN"

# Verify binaries exist
for binary in $MYSQLD_BIN $MYSQLADMIN_BIN $MYSQL_BIN $MYSQL_INSTALL_BIN; do
    if ! command -v "$binary" >/dev/null 2>&1; then
        log "ERROR: $binary not found"
        exit 1
    fi
done

# Initialize database if needed
if [ ! -d "/var/lib/mysql/mysql" ]; then
    log "Initializing MariaDB 12.0 database..."

    # Initialize database with MariaDB 12.0 command
    $MYSQL_INSTALL_BIN --user=mysql --datadir=/var/lib/mysql

    # Start mariadbd temporarily for setup
    $MYSQLD_BIN --user=mysql --datadir=/var/lib/mysql --skip-networking --socket=/tmp/mysql_init.sock &
    MYSQLD_PID=$!

    # Wait for server to start
    log "Waiting for temporary server to start..."
    for _ in {1..30}; do
        if $MYSQLADMIN_BIN --socket=/tmp/mysql_init.sock ping --silent 2>/dev/null; then
            log "Temporary server started successfully"
            break
        fi
        sleep 1
    done

    if ! $MYSQLADMIN_BIN --socket=/tmp/mysql_init.sock ping --silent 2>/dev/null; then
        log "ERROR: Failed to start temporary server"
        exit 1
    fi

    # Set root password
    if [ -n "$MYSQL_ROOT_PASSWORD" ]; then
        log "Setting root password..."
        $MYSQL_BIN --socket=/tmp/mysql_init.sock -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';"

        # Create root user for external access
        $MYSQL_BIN --socket=/tmp/mysql_init.sock -e "CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';"
        $MYSQL_BIN --socket=/tmp/mysql_init.sock -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;"
    fi

    # Create database and user if specified
    if [ -n "$MYSQL_DATABASE" ]; then
        log "Creating database: $MYSQL_DATABASE"
        $MYSQL_BIN --socket=/tmp/mysql_init.sock -e "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\`;"

        if [ -n "$MYSQL_USER" ] && [ -n "$MYSQL_PASSWORD" ]; then
            log "Creating user: $MYSQL_USER"
            $MYSQL_BIN --socket=/tmp/mysql_init.sock -e "CREATE USER IF NOT EXISTS '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';"
            $MYSQL_BIN --socket=/tmp/mysql_init.sock -e "GRANT ALL PRIVILEGES ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%';"
        fi
    fi

    # Run init scripts
    for f in /docker-entrypoint-initdb.d/*; do
        if [ -f "$f" ]; then
            case "$f" in
                *.sh)     log "Running $f"
                          # shellcheck source=/dev/null
                          . "$f" ;;
                *.sql)    log "Running $f"; $MYSQL_BIN --socket=/tmp/mysql_init.sock < "$f" ;;
                *.sql.gz) log "Running $f"; gunzip -c "$f" | $MYSQL_BIN --socket=/tmp/mysql_init.sock ;;
                *)        log "Ignoring $f" ;;
            esac
        fi
    done

    $MYSQL_BIN --socket=/tmp/mysql_init.sock -e "FLUSH PRIVILEGES;"

    # Stop temporary server
    log "Stopping temporary server..."
    kill $MYSQLD_PID
    wait $MYSQLD_PID

    log "Database initialization complete"
fi

log "Starting MariaDB 12.0..."

# Replace command if it's the old mysqld name
if [ "$1" = "mysqld" ] || [ "$1" = "mariadbd" ]; then
    set -- "$MYSQLD_BIN" "${@:2}"
fi

exec "$@"
