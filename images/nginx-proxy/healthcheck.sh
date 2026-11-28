#!/bin/sh
# HEALTHCHECK for the hardened nginx-proxy image. busybox only (no curl).
#
# Healthy when the generated config is valid and nginx is serving:
#   * normally, nginx answers anything on its HTTP port (HTTP_PORT, 80 by
#     default); the fallback server's 503 for an unknown host counts. -Y off so
#     an http_proxy in the environment can't answer in nginx's place.
#   * with ENABLE_PROXY_PROTOCOL on, every listener insists on a PROXY header
#     that wget can't send, so the check falls back to the nginx master process
#     being alive.
set -eu

nginx -t -q

case "${ENABLE_PROXY_PROTOCOL:-false}" in
  1|t|T|true|TRUE|True)
    pid="$(cat /run/nginx/nginx.pid)"
    kill -0 "$pid"
    ;;
  *)
    wget -q -S -O /dev/null -T 5 -Y off "http://127.0.0.1:${HTTP_PORT:-80}/" 2>&1 | grep -q 'HTTP/'
    ;;
esac
