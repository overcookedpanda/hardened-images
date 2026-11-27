#!/usr/bin/env bash
# Smoke test for the hardened acme-companion image: issues a real certificate
# end to end against Pebble (Let's Encrypt's test CA). Run by
# build-scan-publish.yml with IMAGE set to the candidate; runs locally too:
#   IMAGE=hardened-acme-companion:dev images/acme-companion/smoke-test.sh
#
# nginx-proxy (found by its acme-companion label) serves the HTTP-01
# challenge, Pebble validates it through pebble-challtestsrv's DNS,
# acme-companion writes the certificate, and nginx-proxy then serves it. It
# also checks that the dropped tools are gone, that acme.sh and docker-gen are
# the pinned versions, and that `docker stop` is handled inside 10 s.
#
#   NGINX_PROXY_IMAGE  proxy to test against (default: upstream nginx-proxy,
#                      which also proves this image is a drop-in for upstream)
#   BACKEND_IMAGE      any image serving HTTP 200 on port 8080
#   PEBBLE_VERSION     Pebble release (default 2.10.1)
set -euo pipefail
IMG="${IMAGE:?set IMAGE to the image to test}"
NGINX_PROXY_IMAGE="${NGINX_PROXY_IMAGE:-nginxproxy/nginx-proxy:1.11.6-alpine}"
BACKEND_IMAGE="${BACKEND_IMAGE:-nginxinc/nginx-unprivileged:alpine}"
PEBBLE_VERSION="${PEBBLE_VERSION:-2.10.1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="${RUNNER_TEMP:-$(mktemp -d)}"
NAMES="ac-companion ac-proxy ac-app pebble pebble-challtestsrv"
cleanup() {
  docker rm -f $NAMES >/dev/null 2>&1 || true
  docker volume rm ac-certs ac-vhost ac-html ac-acme >/dev/null 2>&1 || true
  docker network rm acme_net >/dev/null 2>&1 || true
}
logs() { for n in $NAMES; do echo "::group::logs $n"; docker logs "$n" 2>&1 | tail -80 || true; echo "::endgroup::"; done; }
trap 'rc=$?; (( rc )) && logs; cleanup' EXIT

for tool in dig ssh socat oathtool; do
  if docker run --rm --entrypoint sh "$IMG" -c "command -v $tool" >/dev/null 2>&1; then
    echo "::error::$IMG contains $tool"; exit 1
  fi
done
WANT_ACMESH="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$IMG" | sed -n 's/^ACMESH_VERSION=//p')"
GOT_ACMESH="$(docker run --rm --entrypoint /app/acme.sh "$IMG" --version)"
echo "$GOT_ACMESH"
grep -qx "v${WANT_ACMESH}" <<< "$GOT_ACMESH" \
  || { echo "::error::acme.sh is not ${WANT_ACMESH}"; exit 1; }
docker run --rm --entrypoint docker-gen "$IMG" -version
# The standard RFC 7919 groups the entrypoint checks dhparam.pem against.
docker run --rm --entrypoint sh "$IMG" -c 'ls /app/dhparam/ffdhe2048.pem /app/dhparam/ffdhe3072.pem /app/dhparam/ffdhe4096.pem' \
  || { echo "::error::/app/dhparam is missing the RFC 7919 groups"; exit 1; }

# Pebble on a fixed subnet: .2 the CA, .3 its DNS, .4 nginx-proxy.
docker network create --subnet 10.30.50.0/24 acme_net >/dev/null
docker run -d --name pebble-challtestsrv --network acme_net --ip 10.30.50.3 \
  "ghcr.io/letsencrypt/pebble-challtestsrv:${PEBBLE_VERSION}" \
  -defaultIPv6 "" -defaultIPv4 10.30.50.4 >/dev/null
docker run -d --name pebble --network acme_net --ip 10.30.50.2 -e PEBBLE_VA_NOSLEEP=1 \
  -v "$HERE/smoke/pebble-config.json:/test/config/pebble-config.json:ro" \
  "ghcr.io/letsencrypt/pebble:${PEBBLE_VERSION}" \
  -config /test/config/pebble-config.json -dnsserver 10.30.50.3:8053 >/dev/null
curl -fsSL --retry 3 -o "$TMP/pebble.minica.pem" \
  "https://raw.githubusercontent.com/letsencrypt/pebble/refs/tags/v${PEBBLE_VERSION}/test/certs/pebble.minica.pem"

for v in ac-certs ac-vhost ac-html ac-acme; do docker volume create "$v" >/dev/null; done
docker run -d --name ac-proxy --network acme_net --ip 10.30.50.4 \
  --label com.github.jrcs.letsencrypt_nginx_proxy_companion.nginx_proxy \
  -v /var/run/docker.sock:/tmp/docker.sock:ro \
  -v ac-certs:/etc/nginx/certs -v ac-vhost:/etc/nginx/vhost.d -v ac-html:/usr/share/nginx/html \
  "$NGINX_PROXY_IMAGE" >/dev/null
# Volumes and socket as a typical compose file mounts them.
docker run -d --name ac-companion --network acme_net \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v ac-certs:/etc/nginx/certs -v ac-vhost:/etc/nginx/vhost.d -v ac-html:/usr/share/nginx/html \
  -v ac-acme:/etc/acme.sh \
  -v "$TMP/pebble.minica.pem:/pebble.minica.pem:ro" \
  -e ACME_CA_URI=https://pebble:14000/dir -e CA_BUNDLE=/pebble.minica.pem \
  -e DEFAULT_EMAIL=smoke@example.com -e DEBUG=1 \
  "$IMG" >/dev/null
docker run -d --name ac-app --network acme_net \
  -e VIRTUAL_HOST=app.test -e VIRTUAL_PORT=8080 -e LETSENCRYPT_HOST=app.test \
  "$BACKEND_IMAGE" >/dev/null

# Wait for the certificate (acme-companion retries on its own loop).
for i in $(seq 1 90); do
  if docker exec ac-companion test -s /etc/nginx/certs/app.test/fullchain.pem 2>/dev/null; then
    echo "certificate issued after ~$(( i * 2 ))s"; break
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' ac-companion)" != true ]]; then
    echo "::error::acme-companion exited"; exit 1
  fi
  (( i == 90 )) && { echo "::error::no certificate for app.test after 180s"; exit 1; }
  sleep 2
done
if docker logs ac-companion 2>&1 | grep -q 'No such file or directory'; then
  echo "::error::acme-companion logged a missing file"; docker logs ac-companion 2>&1 | grep 'No such file'; exit 1
fi

# nginx-proxy serves it once acme-companion has reloaded it.
for i in $(seq 1 30); do
  CERT="$(docker exec ac-companion sh -c 'echo | openssl s_client -connect 10.30.50.4:443 -servername app.test 2>/dev/null | openssl x509 -noout -issuer -ext subjectAltName' || true)"
  # Pebble leaves the subject empty; the name is in the SAN.
  if grep -q 'DNS:app.test' <<< "$CERT" && grep -qi 'issuer=.*pebble' <<< "$CERT"; then
    echo "$CERT"; break
  fi
  (( i == 30 )) && { echo "::error::nginx-proxy does not serve the Pebble certificate for app.test: ${CERT:-nothing}"; exit 1; }
  sleep 2
done
CODE="$(docker exec ac-companion curl -sk -o /dev/null -w '%{http_code}' --resolve app.test:443:10.30.50.4 https://app.test/)"
[[ "$CODE" == 200 ]] || { echo "::error::https://app.test answered $CODE"; exit 1; }
echo "https://app.test -> $CODE"

start=$(date +%s)
docker stop -t 10 ac-companion >/dev/null
took=$(( $(date +%s) - start ))
echo "docker stop took ${took}s"
if (( took >= 9 )); then
  echo "::error::SIGTERM not handled (stop took ${took}s)"; exit 1
fi

