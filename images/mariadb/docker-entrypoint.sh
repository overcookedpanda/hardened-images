#!/bin/bash
set -eo pipefail

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# MariaDB binary names
MYSQLD_BIN="mariadbd"
MYSQLADMIN_BIN="mariadb-admin"
MYSQL_BIN="mariadb"
MYSQL_INSTALL_BIN="mariadb-install-db"

log "Using MariaDB binaries:"
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
# Quote a value as an SQL string literal (escapes \ and ') and an identifier
# (doubles backticks), so a password or name with those characters can't
# break, or inject into, the setup statements.
sql_str() { local v=${1//\\/\\\\}; printf "'%s'" "${v//\'/\'\'}"; }
# shellcheck disable=SC2016 # the backticks are literal
sql_id()  { printf '`%s`' "${1//\`/\`\`}"; }
# A database name as a GRANT pattern: _ and % are wildcards there, so escape
# them to match only that database.
# shellcheck disable=SC2016 # the backticks are literal
sql_db_pattern() { local v=${1//_/\\_}; v=${v//%/\\%}; printf '`%s`' "${v//\`/\`\`}"; }
# Run one setup statement on the temporary server. sql_str's backslash
# escaping assumes backslashes are escape characters, so clear
# NO_BACKSLASH_ESCAPES for this session if a mounted config turns it on; the
# rest of the configured sql_mode, and the init scripts below, are untouched.
setup_sql() {
    $MYSQL_BIN --socket=/tmp/mysql_init.sock -e "SET SESSION sql_mode = TRIM(BOTH ',' FROM REPLACE(CONCAT(',', @@SESSION.sql_mode, ','), ',NO_BACKSLASH_ESCAPES,', ',')); $1"
}

if [ ! -d "/var/lib/mysql/mysql" ]; then
    log "Initializing MariaDB database..."

    # No test database. The anonymous accounts it would also leave are dropped
    # below, once the temporary server is up.
    $MYSQL_INSTALL_BIN --user=mysql --datadir=/var/lib/mysql --skip-test-db

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

    # mariadb-install-db creates anonymous accounts (''@localhost and
    # ''@<hostname>). A client connecting from localhost matches them before
    # 'user'@'%', so MYSQL_USER could not log in over 127.0.0.1. They are also
    # an unauthenticated way in, so drop them.
    setup_sql "DELETE FROM mysql.global_priv WHERE User=''; FLUSH PRIVILEGES;"

    # Set root password
    if [ -n "$MYSQL_ROOT_PASSWORD" ]; then
        log "Setting root password..."
        setup_sql "ALTER USER 'root'@'localhost' IDENTIFIED BY $(sql_str "$MYSQL_ROOT_PASSWORD");"

        # Create root user for external access
        setup_sql "CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY $(sql_str "$MYSQL_ROOT_PASSWORD");"
        setup_sql "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;"
    fi

    # Create database and user if specified
    if [ -n "$MYSQL_DATABASE" ]; then
        log "Creating database: $MYSQL_DATABASE"
        setup_sql "CREATE DATABASE IF NOT EXISTS $(sql_id "$MYSQL_DATABASE");"

        if [ -n "$MYSQL_USER" ] && [ -n "$MYSQL_PASSWORD" ]; then
            log "Creating user: $MYSQL_USER"
            setup_sql "CREATE USER IF NOT EXISTS $(sql_str "$MYSQL_USER")@'%' IDENTIFIED BY $(sql_str "$MYSQL_PASSWORD");"
            setup_sql "GRANT ALL PRIVILEGES ON $(sql_db_pattern "$MYSQL_DATABASE").* TO $(sql_str "$MYSQL_USER")@'%';"
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

log "Starting MariaDB..."

# Replace command if it's the old mysqld name
if [ "$1" = "mysqld" ] || [ "$1" = "mariadbd" ]; then
    set -- "$MYSQLD_BIN" "${@:2}"
fi

exec "$@"
