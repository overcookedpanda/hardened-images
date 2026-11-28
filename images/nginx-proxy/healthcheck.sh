#!/bin/sh
# HEALTHCHECK for the hardened nginx-proxy image. busybox only (no curl).
#
# Healthy when the generated config is valid, the nginx master is alive and,
# where nginx has a plain HTTP listener, that listener answers. Anything counts
# as an answer, the fallback server's 503 for an unknown host included.
#
# The port is read from the running config (nginx -T), not from HTTP_PORT: a
# DEFAULT_HOST vhost with its own EXTERNAL_HTTP_PORT can leave nothing on
# HTTP_PORT. Listeners with ssl, quic or proxy_protocol are skipped, since wget
# can't speak them; when only those exist (HTTPS-only, ENABLE_PROXY_PROTOCOL)
# the master process check stands alone. -Y off so an http_proxy in the
# environment can't answer in nginx's place.
set -eu

nginx -t -q

pid="$(cat /run/nginx/nginx.pid)"
kill -0 "$pid"

port="$(nginx -T 2>/dev/null | awk '
  $1 == "listen" && $0 !~ /(ssl|quic|proxy_protocol|unix:|\[)/ {
    p = $2; sub(/;$/, "", p); sub(/.*:/, "", p); print p; exit
  }')"

if [ -n "$port" ]; then
  wget -q -S -O /dev/null -T 5 -Y off "http://127.0.0.1:${port}/" 2>&1 | grep -q 'HTTP/'
fi
