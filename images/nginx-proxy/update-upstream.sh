#!/usr/bin/env bash
# Refresh upstream/ from an nginx-proxy release tag, e.g.
#   ./update-upstream.sh 1.11.7
# then set NGINX_PROXY_VERSION in the Dockerfile to the same tag, review the
# diff (git diff upstream/) and compare upstream's app/docker-entrypoint.sh
# and Dockerfile.alpine against ours for changes to port.
set -euo pipefail
TAG="${1:?usage: $0 <nginx-proxy tag>}"
BASE="https://raw.githubusercontent.com/nginx-proxy/nginx-proxy/${TAG}"
cd "$(dirname "$0")/upstream"
fetch() { curl -fsSL --retry 3 -o "$2" "${BASE}/$1"; }
fetch nginx.tmpl nginx.tmpl
fetch network_internal.conf network_internal.conf
fetch LICENSE LICENSE
fetch app/Procfile Procfile
for bits in 2048 3072 4096; do
  fetch "app/dhparam/ffdhe${bits}.pem" "dhparam/ffdhe${bits}.pem"
done
echo "upstream/ now at nginx-proxy ${TAG}; also check:"
echo "  ${BASE}/app/docker-entrypoint.sh"
echo "  ${BASE}/Dockerfile.alpine"
