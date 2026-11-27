#!/usr/bin/env bash
# Smoke test for the hardened MariaDB image. Run by build-scan-publish.yml with
# IMAGE set to the candidate; runs locally too:
#   IMAGE=hardened-mariadb:dev images/mariadb/smoke-test.sh
#
# Checks that the image still is a working MariaDB, not just that it builds:
#   * hardening: runs as mysql, no setuid/setgid binaries, no curl or gnupg,
#     no anonymous accounts;
#   * first start initialises the data directory, sets the root password and
#     creates MYSQL_DATABASE and MYSQL_USER;
#   * the app user can connect over TCP and write to its database;
#   * the HEALTHCHECK goes healthy;
#   * `docker stop` shuts mariadbd down cleanly well inside the 10 s kill.
set -euo pipefail
IMG="${IMAGE:?set IMAGE to the image to test}"
NAME=mariadb-smoke
trap 'rc=$?; (( rc )) && docker logs "$NAME" 2>&1 | tail -80; docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

user="$(docker inspect -f '{{.Config.User}}' "$IMG")"
[[ "$user" == mysql ]] || { echo "::error::$IMG runs as '${user:-root}', expected mysql"; exit 1; }

for tool in curl gpg; do
  if docker run --rm --entrypoint sh "$IMG" -c "command -v $tool" >/dev/null 2>&1; then
    echo "::error::$IMG contains $tool"; exit 1
  fi
done
SUID="$(docker run --rm --entrypoint sh "$IMG" -c 'find /usr/bin /usr/sbin /bin /sbin -perm /6000 -type f 2>/dev/null' || true)"
[[ -z "$SUID" ]] || { echo "::error::setuid/setgid binaries present:"; echo "$SUID"; exit 1; }

docker run -d --name "$NAME" \
  -e MYSQL_ROOT_PASSWORD=smoke-root -e MYSQL_DATABASE=smoke \
  -e MYSQL_USER=app -e MYSQL_PASSWORD=smoke-app \
  --health-interval=2s --health-start-period=5s "$IMG" >/dev/null

for i in $(seq 1 60); do
  status="$(docker inspect -f '{{.State.Health.Status}}' "$NAME")"
  [[ "$status" == healthy ]] && { echo "healthy after ~$(( i * 2 ))s"; break; }
  [[ "$(docker inspect -f '{{.State.Running}}' "$NAME")" == true ]] \
    || { echo "::error::mariadb exited"; exit 1; }
  (( i == 60 )) && { echo "::error::not healthy after 120s ($status)"; exit 1; }
  sleep 2
done

# The entrypoint's temporary init server can answer ping before the real one
# listens on TCP, so retry the first TCP query briefly.
q() { docker exec "$NAME" mariadb -h 127.0.0.1 -uapp -psmoke-app smoke -N -e "$1"; }
for i in $(seq 1 15); do q 'SELECT 1' >/dev/null 2>&1 && break; sleep 1; done
q 'CREATE TABLE t (id INT PRIMARY KEY); INSERT INTO t VALUES (42);'
got="$(q 'SELECT id FROM t')"
[[ "$got" == 42 ]] || { echo "::error::app user could not write and read back (got '$got')"; exit 1; }
docker exec "$NAME" mariadb -h 127.0.0.1 -uroot -psmoke-root -N -e 'SELECT VERSION()'
anon="$(docker exec "$NAME" mariadb -h 127.0.0.1 -uroot -psmoke-root -N -e "SELECT COUNT(*) FROM mysql.global_priv WHERE User=''")"
[[ "$anon" == 0 ]] || { echo "::error::$anon anonymous account(s) present"; exit 1; }

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
echo "MariaDB smoke test passed."
