#!/usr/bin/env bash
# Refresh upstream/ from an acme-companion release tag, e.g.
#   ./update-upstream.sh v2.8.3
# then set ACME_COMPANION_VERSION in the Dockerfile to the same tag, check
# upstream's Dockerfile at that tag for a new ACMESH_VERSION or package, and
# review the diff (git diff upstream/).
set -euo pipefail
TAG="${1:?usage: $0 <acme-companion tag>}"
BASE="https://raw.githubusercontent.com/nginx-proxy/acme-companion/${TAG}"
cd "$(dirname "$0")/upstream"
fetch() { curl -fsSL --retry 3 -o "$2" "${BASE}/$1"; }
for f in cert_status cleanup_test_artifacts dhparam.pem.default entrypoint.sh \
         force_renew functions.sh letsencrypt_service letsencrypt_service_data.tmpl \
         nginx_location.conf signal_le_service start.sh; do
  fetch "app/${f}" "${f}"
done
for bits in 2048 3072 4096; do
  fetch "app/dhparam/ffdhe${bits}.pem" "dhparam/ffdhe${bits}.pem"
done
fetch LICENSE LICENSE
echo "upstream/ now at acme-companion ${TAG}; also check:"
echo "  ${BASE}/Dockerfile (ACMESH_VERSION, packages, docker-gen version)"
echo "  ${BASE}/install_acme.sh"
