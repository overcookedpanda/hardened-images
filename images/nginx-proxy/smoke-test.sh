#!/usr/bin/env bash
# Smoke test for the hardened nginx-proxy image. Run by build-scan-publish.yml
# with IMAGE set to the candidate; runs locally too:
#   IMAGE=hardened-nginx-proxy:dev images/nginx-proxy/smoke-test.sh
#
# The image has to still be nginx-proxy, not just build:
#   * hardening: no bash, openssl, apk or curl; nginx workers run unprivileged;
#   * docker-gen picks up a container with VIRTUAL_HOST and nginx routes to it,
#     and drops it again when the container goes away (fallback answers 503);
#   * the template patch holds: ENABLE_HTTP2=false leaves no `http2 on`;
#   * the image's HEALTHCHECK command passes on a serving container;
#   * the reload command acme-companion execs in this container works;
#   * `docker stop` is handled well under the 10 s kill.
#
# Needs a docker login to dhi.io for the test backend (BACKEND_IMAGE), or set
# BACKEND_IMAGE to any image that serves HTTP 200 on port 8080.
set -euo pipefail
trap 'docker rm -f np-smoke np-backend >/dev/null 2>&1 || true; docker network rm np-smoke >/dev/null 2>&1 || true' EXIT
IMG="${IMAGE:?set IMAGE to the image to test}"
BACKEND_IMAGE="${BACKEND_IMAGE:-dhi.io/nginx:1.31.10-alpine3.24}"

for tool in bash openssl apk curl; do
  if docker run --rm --entrypoint sh "$IMG" -c "command -v $tool" >/dev/null 2>&1; then
    echo "::error::$IMG contains $tool"; exit 1
  fi
done
docker run --rm --entrypoint nginx "$IMG" -t
docker run --rm --entrypoint docker-gen "$IMG" -version
docker run --rm --entrypoint forego "$IMG" version

docker network create np-smoke >/dev/null
docker run -d --name np-smoke --network np-smoke -p 8080:80 \
  -v /var/run/docker.sock:/tmp/docker.sock:ro \
  -e ENABLE_HTTP2=false -e TRUST_DOWNSTREAM_PROXY=false \
  "$IMG"

# GET http://127.0.0.1:8080/ with a Host header; prints the status.
status() { curl -s -o /dev/null -w '%{http_code}' -H "Host: $1" http://127.0.0.1:8080/ || true; }
# Wait until a request for host $1 answers $2.
expect() {
  local got
  for _ in $(seq 1 30); do
    got="$(status "$1")"
    [[ "$got" == "$2" ]] && { echo "$1 -> $got"; return 0; }
    if [[ "$(docker inspect -f '{{.State.Running}}' np-smoke)" != true ]]; then
      echo "::error::nginx-proxy exited"; docker logs np-smoke; return 1
    fi
    sleep 1
  done
  echo "::error::$1 answered ${got:-nothing}, expected $2"; docker logs np-smoke; return 1
}

expect unknown.test 503

# The image's HEALTHCHECK command passes while only the fallback (503) answers.
HC="$(docker inspect -f '{{join .Config.Healthcheck.Test " "}}' np-smoke)"
[[ "$HC" == CMD-SHELL* ]] || { echo "::error::no HEALTHCHECK in the image ($HC)"; exit 1; }
docker exec np-smoke sh -c "${HC#CMD-SHELL }" \
  || { echo "::error::the HEALTHCHECK command fails on a serving nginx-proxy"; exit 1; }

# A backend declared the usual way: VIRTUAL_HOST/PORT on a
# shared network. DHI nginx serves its welcome page on 8080.
docker run -d --name np-backend --network np-smoke \
  -e VIRTUAL_HOST=app.test -e VIRTUAL_PORT=8080 \
  "$BACKEND_IMAGE" >/dev/null
expect app.test 200
curl -fsS -H 'Host: app.test' http://127.0.0.1:8080/ | grep -qi nginx \
  || { echo "::error::app.test was not proxied to the backend"; exit 1; }

CONF="$(docker exec np-smoke cat /etc/nginx/conf.d/default.conf)"
grep -q 'server_name app.test;' <<< "$CONF" \
  || { echo "::error::docker-gen did not write a server for app.test"; exit 1; }
if grep -q 'http2 on' <<< "$CONF"; then
  echo "::error::ENABLE_HTTP2=false but the config enables http2 (template patch missing?)"; exit 1
fi

# nginx master as root (reads root-only keys), workers as nginx.
PS="$(docker exec np-smoke ps -o user,args)"
echo "$PS"
grep -E 'nginx: worker process' <<< "$PS" | grep -vqE '^ *(nginx|65532) ' \
  && { echo "::error::nginx workers are not running as nginx"; exit 1; }
grep -q 'docker-gen -watch' <<< "$PS" \
  || { echo "::error::docker-gen is not running"; exit 1; }

# acme-companion's reload, verbatim from its app/functions.sh.
docker exec np-smoke sh -c "/app/docker-entrypoint.sh /usr/local/bin/docker-gen /app/nginx.tmpl /etc/nginx/conf.d/default.conf; /usr/sbin/nginx -s reload"
expect app.test 200

docker rm -f np-backend >/dev/null
expect app.test 503

start=$(date +%s)
docker stop -t 10 np-smoke >/dev/null
took=$(( $(date +%s) - start ))
echo "docker stop took ${took}s"
if (( took >= 9 )); then
  echo "::error::SIGTERM not handled (stop took ${took}s)"; exit 1
fi

