#!/usr/bin/env bash
# Smoke test for the hardened MariaDB image. Run by build-scan-publish.yml with
# IMAGE set to the candidate; runs locally too:
#   IMAGE=hardened-mariadb:dev images/mariadb/smoke-test.sh
#
# Checks that the image still is a working MariaDB, not just that it builds:
#   * hardening: runs as mysql, no setuid/setgid binaries, no curl or gnupg,
#     no anonymous accounts, and the app grant covers only its own database;
#   * the image ships an empty /var/lib/mysql, and first start initialises
#     it, sets the root password and creates MYSQL_DATABASE and MYSQL_USER;
#   * the app user, whose password has a quote and a backslash, can connect
#     over TCP and write to its database;
#   * the HEALTHCHECK goes healthy;
#   * `docker stop` shuts mariadbd down cleanly well inside the 10 s kill.
#   * with NO_BACKSLASH_ESCAPES set in a mounted config, a root password with
#     a backslash still works.
#   * a container whose first-start setup failed refuses to start on restart.
set -euo pipefail
IMG="${IMAGE:?set IMAGE to the image to test}"
NAME=mariadb-smoke
# A quote and a backslash, so the entrypoint's SQL quoting is exercised.
APP_PW="smoke'app\\pw"
CONF_DIR="$(mktemp -d)"
INIT_DIR="$(mktemp -d)"
trap 'rc=$?; (( rc )) && docker logs "$NAME" 2>&1 | tail -80; docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$CONF_DIR" "$INIT_DIR"' EXIT

user="$(docker inspect -f '{{.Config.User}}' "$IMG")"
[[ "$user" == mysql ]] || { echo "::error::$IMG runs as '${user:-root}', expected mysql"; exit 1; }

for tool in curl gpg; do
  if docker run --rm --entrypoint sh "$IMG" -c "command -v $tool" >/dev/null 2>&1; then
    echo "::error::$IMG contains $tool"; exit 1
  fi
done
# The package's postinst initialises a datadir; if one ships in the image the
# entrypoint skips setup and ignores every MYSQL_* variable.
DATADIR="$(docker run --rm --entrypoint sh "$IMG" -c 'ls -A /var/lib/mysql')"
[[ -z "$DATADIR" ]] || { echo "::error::$IMG ships a pre-initialised /var/lib/mysql:"; echo "$DATADIR"; exit 1; }
SUID="$(docker run --rm --entrypoint sh "$IMG" -c 'find /usr/bin /usr/sbin /bin /sbin -perm /6000 -type f 2>/dev/null' || true)"
[[ -z "$SUID" ]] || { echo "::error::setuid/setgid binaries present:"; echo "$SUID"; exit 1; }

docker run -d --name "$NAME" \
  -e MYSQL_ROOT_PASSWORD=smoke-root -e MYSQL_DATABASE=smoke_db \
  -e MYSQL_USER=app -e MYSQL_PASSWORD="$APP_PW" \
  --health-interval=2s --health-start-period=5s "$IMG" >/dev/null

wait_healthy() {
  local i status
  for i in $(seq 1 60); do
    status="$(docker inspect -f '{{.State.Health.Status}}' "$NAME")"
    [[ "$status" == healthy ]] && { echo "healthy after ~$(( i * 2 ))s"; return 0; }
    [[ "$(docker inspect -f '{{.State.Running}}' "$NAME")" == true ]] \
      || { echo "::error::mariadb exited"; exit 1; }
    (( i == 60 )) && { echo "::error::not healthy after 120s ($status)"; exit 1; }
    sleep 2
  done
}
wait_healthy

# The entrypoint's temporary init server can answer ping before the real one
# listens on TCP, so retry the first TCP query briefly.
q() { docker exec "$NAME" mariadb -h 127.0.0.1 -uapp "-p$APP_PW" smoke_db -N -e "$1"; }
for i in $(seq 1 15); do q 'SELECT 1' >/dev/null 2>&1 && break; sleep 1; done
q 'CREATE TABLE t (id INT PRIMARY KEY); INSERT INTO t VALUES (42);'
got="$(q 'SELECT id FROM t')"
[[ "$got" == 42 ]] || { echo "::error::app user could not write and read back (got '$got')"; exit 1; }
docker exec "$NAME" mariadb -h 127.0.0.1 -uroot -psmoke-root -N -e 'SELECT VERSION()'
anon="$(docker exec "$NAME" mariadb -h 127.0.0.1 -uroot -psmoke-root -N -e "SELECT COUNT(*) FROM mysql.global_priv WHERE User=''")"
[[ "$anon" == 0 ]] || { echo "::error::$anon anonymous account(s) present"; exit 1; }
# The grant on smoke_db must not spread to a database matching smoke_db as a
# pattern (_ is a wildcard in GRANT).
docker exec "$NAME" mariadb -h 127.0.0.1 -uroot -psmoke-root -e 'CREATE DATABASE smokeXdb'
if docker exec "$NAME" mariadb -h 127.0.0.1 -uapp "-p$APP_PW" smokeXdb -e 'SELECT 1' >/dev/null 2>&1; then
  echo "::error::app user's grant also covers smokeXdb"; exit 1
fi

PID1_UID="$(docker exec "$NAME" sh -c "awk '/^Uid:/{print \$2}' /proc/1/status")"
MYSQL_UID="$(docker exec "$NAME" id -u mysql)"
[[ "$PID1_UID" == "$MYSQL_UID" ]] || { echo "::error::PID 1 runs as uid $PID1_UID, expected mysql ($MYSQL_UID)"; exit 1; }

start=$(date +%s)
docker stop -t 10 "$NAME" >/dev/null
took=$(( $(date +%s) - start ))
echo "docker stop took ${took}s"
(( took < 9 )) || { echo "::error::SIGTERM not handled (stop took ${took}s)"; exit 1; }
docker logs "$NAME" 2>&1 | grep -qiE 'shutdown complete' \
  || { echo "::error::no clean shutdown in the log"; exit 1; }
docker rm -f "$NAME" >/dev/null

# A mounted config may set NO_BACKSLASH_ESCAPES; the entrypoint's escaping must
# still hand MariaDB the password exactly as given.
ROOT_PW='smoke\root'
printf '[mysqld]\nsql_mode=NO_BACKSLASH_ESCAPES\n' > "$CONF_DIR/sql-mode.cnf"
chmod 755 "$CONF_DIR"; chmod 644 "$CONF_DIR/sql-mode.cnf"
docker run -d --name "$NAME" -e MYSQL_ROOT_PASSWORD="$ROOT_PW" \
  -v "$CONF_DIR:/etc/mysql/conf.d:ro" \
  --health-interval=2s --health-start-period=5s "$IMG" >/dev/null
wait_healthy
rq() { docker exec "$NAME" mariadb -h 127.0.0.1 -uroot "-p$ROOT_PW" -N -e "$1"; }
for i in $(seq 1 15); do rq 'SELECT 1' >/dev/null 2>&1 && break; sleep 1; done
mode="$(rq 'SELECT @@GLOBAL.sql_mode')" \
  || { echo "::error::root password with a backslash rejected under NO_BACKSLASH_ESCAPES"; exit 1; }
[[ "$mode" == *NO_BACKSLASH_ESCAPES* ]] \
  || { echo "::error::mounted config not applied (sql_mode '$mode')"; exit 1; }
docker rm -f "$NAME" >/dev/null

# Setup that fails partway (here an init script) must not leave a datadir that
# a restart then runs with.
printf 'echo "failing on purpose"; false\n' > "$INIT_DIR/fail.sh"
chmod 755 "$INIT_DIR"; chmod 644 "$INIT_DIR/fail.sh"
docker run -d --name "$NAME" -e MYSQL_ROOT_PASSWORD=smoke-root \
  -v "$INIT_DIR:/docker-entrypoint-initdb.d:ro" "$IMG" >/dev/null
[[ "$(docker wait "$NAME")" != 0 ]] || { echo "::error::setup with a failing init script did not fail"; exit 1; }
docker start "$NAME" >/dev/null
[[ "$(docker wait "$NAME")" != 0 ]] || { echo "::error::container started after a failed setup"; exit 1; }
docker logs "$NAME" 2>&1 | grep -q 'earlier initialization of /var/lib/mysql did not finish' \
  || { echo "::error::restart after a failed setup did not refuse with the expected message"; exit 1; }

echo "MariaDB smoke test passed."
