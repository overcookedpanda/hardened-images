#!/usr/bin/env bash
# Smoke test for the hardened Airflow image. Run by build-scan-publish.yml with
# IMAGE set to the candidate; runs locally too:
#   IMAGE=hardened-airflow:dev images/airflow/smoke-test.sh
#
# Checks that the image still is a working Airflow, not just that it builds:
#   * hardening: runs as airflow, no setuid/setgid binaries, no sudo, docker
#     CLI or uv, no SQL Server driver, no Microsoft or Docker apt repos, the
#     Kubernetes provider stays out, and `pip check` is clean;
#   * the shipped constraints file pins every installed package as installed;
#   * the Postgres and StatsD support it adds import;
#   * an arbitrary uid with gid 0 (OpenShift style) still starts;
#   * a DAG mounted into /opt/airflow/dags parses and runs end to end, Bash
#     and Python tasks, with `airflow dags test`;
#   * `airflow db migrate` works against a real Postgres metadata database;
#   * webserver and scheduler come up and /health reports both healthy;
#   * `docker stop` shuts them down well inside the 10 s kill.
set -euo pipefail
IMG="${IMAGE:?set IMAGE to the image to test}"
SUFFIX="$$"
NET="airflow-smoke-$SUFFIX"
PG="airflow-smoke-pg-$SUFFIX"
AF="airflow-smoke-$SUFFIX"
DAGS="$(mktemp -d)"
chmod 755 "$DAGS"
cleanup() {
  local rc=$?
  if (( rc )); then
    docker logs "$AF" 2>&1 | tail -80 || true
  fi
  docker rm -f "$AF" "$PG" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$DAGS"
}
trap cleanup EXIT

fail() { echo "::error::$*"; exit 1; }
# Run a command in a throwaway container from the image.
in_image() { docker run --rm --entrypoint bash "$IMG" -c "$1"; }

echo "== hardening"
user="$(docker inspect -f '{{.Config.User}}' "$IMG")"
[[ "$user" == airflow || "$user" == 50000 ]] || fail "$IMG runs as '${user:-root}', expected airflow"

SUID="$(in_image 'find / -xdev -perm /6000 -type f 2>/dev/null' || true)"
[[ -z "$SUID" ]] || { echo "$SUID"; fail "setuid/setgid binaries present"; }

for tool in sudo docker uv; do
  if in_image "command -v $tool" >/dev/null 2>&1; then
    fail "$IMG contains $tool"
  fi
done
PKGS="$(in_image "dpkg-query -W -f '\${Package}\n' 'msodbcsql*' 'mssql-tools*' docker-ce-cli sudo 2>/dev/null" || true)"
[[ -z "$PKGS" ]] || { echo "$PKGS"; fail "removed packages are back"; }
REPOS="$(in_image 'grep -rl -e packages.microsoft.com -e download.docker.com /etc/apt/ 2>/dev/null' || true)"
[[ -z "$REPOS" ]] || { echo "$REPOS"; fail "Microsoft or Docker apt repo still configured"; }

docker run --rm --entrypoint python "$IMG" -c '
import importlib, sys
for m in ("psycopg2", "statsd", "airflow.providers.postgres", "airflow.providers.fab"):
    importlib.import_module(m)
try:
    import airflow.providers.cncf.kubernetes  # noqa: F401
except ImportError:
    pass
else:
    sys.exit("Kubernetes provider is installed again")
import airflow
print("airflow", airflow.__version__)
'
in_image 'pip check'

# Derived images install against /opt/hardened-airflow/constraints.txt, so it
# must pin every installed package at the version the image has.
docker run --rm --entrypoint python "$IMG" -c '
import re, sys
from importlib.metadata import distributions
norm = lambda n: re.sub(r"[-_.]+", "-", n).lower()
pins = {}
for line in open("/opt/hardened-airflow/constraints.txt", encoding="utf-8"):
    m = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==(\S+)", line)
    if m:
        pins[norm(m.group(1))] = m.group(2)
seen, bad = set(), []
for d in distributions():
    key = norm(d.metadata["Name"])
    if key in seen or key in {"pip", "setuptools", "wheel"}:
        continue
    seen.add(key)
    if pins.get(key) != d.version:
        bad.append(f"{key} installed {d.version}, pinned {pins.get(key)}")
if bad:
    sys.exit("constraints.txt out of step with the image:\n" + "\n".join(bad))
print(f"constraints.txt pins all {len(seen)} installed packages")
'

echo "== arbitrary uid"
docker run --rm --user 12345:0 "$IMG" version >/dev/null \
  || fail "image does not start as an arbitrary uid with gid 0"

echo "== DAG parse and run (sqlite)"
cat > "$DAGS/smoke_dag.py" <<'PY'
from datetime import datetime

from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator


def _check(ti):
    assert ti.xcom_pull(task_ids="hello") == "hello from bash"


with DAG("smoke_dag", start_date=datetime(2024, 1, 1), schedule=None, catchup=False):
    BashOperator(task_id="hello", bash_command="echo 'hello from bash'") >> \
        PythonOperator(task_id="check", python_callable=_check)
PY
chmod 644 "$DAGS/smoke_dag.py"

# `airflow dags list-import-errors` reads errors the scheduler recorded, so
# without a scheduler it reports none even for a broken DAG. Parse with a
# DagBag instead, which is what the scheduler does.
docker run --rm -v "$DAGS:/opt/airflow/dags:ro" --entrypoint python "$IMG" -c '
import sys
from airflow.models import DagBag
bag = DagBag(include_examples=False)
if bag.import_errors:
    sys.exit(f"DAG import errors: {bag.import_errors}")
if "smoke_dag" not in bag.dags:
    sys.exit(f"smoke_dag not parsed; found {sorted(bag.dags)}")
' || fail "DAGs folder did not parse"

OUT="$(docker run --rm -v "$DAGS:/opt/airflow/dags:ro" "$IMG" \
  bash -c 'airflow db migrate >/dev/null && airflow dags test smoke_dag 2024-01-01' 2>&1)" \
  || { echo "$OUT" | tail -60; fail "airflow dags test failed"; }
grep -Eq 'DagRun Finished: dag_id=smoke_dag,.* state=success' <<< "$OUT" \
  || { echo "$OUT" | tail -60; fail "smoke_dag did not finish successfully"; }
echo "smoke_dag ran successfully"

echo "== Postgres metadata database"
docker network create "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" \
  -e POSTGRES_USER=airflow -e POSTGRES_PASSWORD=airflow -e POSTGRES_DB=airflow \
  postgres:17-alpine >/dev/null
for i in $(seq 1 30); do
  docker exec "$PG" pg_isready -U airflow -d airflow >/dev/null 2>&1 && break
  (( i == 30 )) && fail "postgres not ready after 60s"
  sleep 2
done
docker run --rm --network "$NET" \
  -e AIRFLOW__DATABASE__SQL_ALCHEMY_CONN="postgresql+psycopg2://airflow:airflow@$PG/airflow" \
  "$IMG" bash -c 'airflow db migrate >/dev/null && airflow db check' \
  || fail "airflow db migrate against Postgres failed"

echo "== webserver and scheduler"
docker run -d --name "$AF" --network "$NET" \
  -e AIRFLOW__DATABASE__SQL_ALCHEMY_CONN="postgresql+psycopg2://airflow:airflow@$PG/airflow" \
  -v "$DAGS:/opt/airflow/dags:ro" \
  "$IMG" bash -c 'airflow scheduler & exec airflow webserver -p 8080' >/dev/null

HEALTH=""
for i in $(seq 1 60); do
  [[ "$(docker inspect -f '{{.State.Running}}' "$AF")" == true ]] || fail "airflow container exited"
  HEALTH="$(docker exec "$AF" python -c '
import json, urllib.request
h = json.load(urllib.request.urlopen("http://127.0.0.1:8080/health", timeout=5))
print(h["metadatabase"]["status"], h["scheduler"]["status"])
' 2>/dev/null || true)"
  [[ "$HEALTH" == "healthy healthy" ]] && { echo "healthy after ~$(( i * 3 ))s"; break; }
  (( i == 60 )) && fail "/health not healthy after 180s (last: ${HEALTH:-no answer})"
  sleep 3
done

echo "== clean shutdown"
# dumb-init is PID 1 and forwards SIGTERM to the process group; a SIGKILL at
# the 10 s mark (exit 137) means something ignored it.
start=$SECONDS
docker stop -t 10 "$AF" >/dev/null
took=$(( SECONDS - start ))
code="$(docker inspect -f '{{.State.ExitCode}}' "$AF")"
[[ "$code" != 137 ]] || fail "airflow was killed after ${took}s instead of stopping on SIGTERM"
(( took < 10 )) || fail "docker stop took ${took}s"
echo "stopped in ${took}s (exit $code)"

echo "smoke test passed"
