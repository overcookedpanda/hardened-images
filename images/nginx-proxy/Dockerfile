# syntax=docker/dockerfile:1
#
# hardened nginx-proxy: nginx-proxy (docker-gen auto-config for nginx) rebuilt on
# the Docker Hardened Image for nginx, as a drop-in for
# nginxproxy/nginx-proxy:1.11.6-alpine.
#
# Built, smoke-tested, scanned and published by
# .github/workflows/nginx-proxy.yml (via build-scan-publish.yml), as
# ghcr.io/<owner>/hardened-nginx-proxy. See README.md for what differs from
# upstream and how to switch to it.
#
# Pulling from dhi.io needs `docker login dhi.io`, even for free images.

# docker-gen and forego are pinned in tools/go.mod (as Go tool dependencies),
# together with the security floors for their libraries; go.sum pins the
# source. docker-gen tags have no "v", so go.mod can only name tag 0.17.2 by
# its commit; the build checks that DOCKER_GEN_VERSION and that commit agree.
ARG DOCKER_GEN_VERSION=0.17.2
ARG DOCKER_GEN_COMMIT=497e50d07d3a
ARG NGINX_PROXY_VERSION=1.11.6

# ---------------------------------------------------------------------------
# docker-gen and forego, built from source with the current Go 1.26 toolchain
# instead of copied out of nginxproxy/docker-gen and nginxproxy/forego, so the
# Go standard library in them is as new as DHI's golang image, and libraries
# with fixed CVEs can be raised past what upstream's own go.mod pins.
# ---------------------------------------------------------------------------
FROM dhi.io/golang:1.27-alpine3.24-dev AS build
ARG DOCKER_GEN_VERSION
ARG DOCKER_GEN_COMMIT
ENV CGO_ENABLED=0 GOFLAGS="-trimpath -mod=readonly" GOTOOLCHAIN=local
WORKDIR /src
COPY tools/go.mod tools/go.sum ./
RUN go mod download
RUN set -e; \
    gen="$(go list -m -f '{{.Version}}' github.com/nginx-proxy/docker-gen)"; \
    case "$gen" in *"-${DOCKER_GEN_COMMIT}") ;; \
        *) echo "tools/go.mod has docker-gen $gen, not commit ${DOCKER_GEN_COMMIT} (${DOCKER_GEN_VERSION})" >&2; exit 1 ;; \
    esac; \
    forego="$(go list -m -f '{{.Version}}' github.com/nginx-proxy/forego)"; \
    go build -ldflags "-s -w -X main.buildVersion=${DOCKER_GEN_VERSION}" -o /out/ \
        github.com/nginx-proxy/docker-gen/cmd/docker-gen; \
    go build -ldflags "-s -w -X main.Version=${forego#v}" -o /out/ \
        github.com/nginx-proxy/forego; \
    /out/docker-gen -version; /out/forego version

# ---------------------------------------------------------------------------
# /app: upstream's files at NGINX_PROXY_VERSION (upstream/, see
# update-upstream.sh) with our template patch applied. The build fails if the
# patch no longer applies, which is the signal to revisit it on a bump.
# ---------------------------------------------------------------------------
FROM dhi.io/nginx:1.31.10-alpine3.24-dev AS app
COPY upstream/ /app/
COPY patches/ /tmp/patches/
RUN set -e; \
    command -v patch >/dev/null || apk add --no-cache patch; \
    for p in /tmp/patches/*.patch; do patch /app/nginx.tmpl "$p"; done; \
    rm -f /app/*.orig

# ---------------------------------------------------------------------------
# Runtime: the hardened nginx image plus the two Go binaries, the template and
# a POSIX-sh entrypoint. No bash, openssl, apk or curl.
# ---------------------------------------------------------------------------
FROM dhi.io/nginx:1.31.10-alpine3.24
ARG DOCKER_GEN_VERSION
ARG NGINX_PROXY_VERSION

# Numeric: the base's /etc/passwd has no root entry, so `USER root` fails.
USER 0:0

# The base has busybox but not its applet links. The entrypoint needs sh,
# awk, sed, grep, tr and cp, and acme-companion reloads nginx through
# `sh -c` in this container, so install the links (exec form: no /bin/sh yet).
RUN ["/bin/busybox", "--install", "-s"]

# Name the two users this image runs as. root has no passwd entry in the base
# (it is built to run as 65532 only), and nginx.conf's `user nginx;` needs an
# entry for the workers. Existing entries are kept; the files go to the build
# log so a change in the base is easy to spot.
RUN set -e; \
    grep -q '^root:' /etc/passwd || echo 'root:x:0:0:root:/root:/sbin/nologin' >> /etc/passwd; \
    grep -q '^root:' /etc/group || echo 'root:x:0:' >> /etc/group; \
    grep -q '^nginx:' /etc/group || echo 'nginx:x:65532:' >> /etc/group; \
    grep -q '^nginx:' /etc/passwd \
        || echo 'nginx:x:65532:65532:nginx:/var/lib/nginx:/sbin/nologin' >> /etc/passwd; \
    cat /etc/passwd /etc/group

# Same layout upstream creates. DHI's empty stream.conf would otherwise be
# included inside http {}; its default.conf is overwritten by docker-gen on
# start, as upstream's is.
RUN set -e; \
    rm -f /etc/nginx/conf.d/stream.conf; \
    mkdir -p /etc/nginx/toplevel.conf.d /etc/nginx/dhparam /etc/nginx/certs \
        /usr/share/nginx/html/errors; \
    chown 65532:65532 /etc/nginx/dhparam

COPY --from=build /out/docker-gen /out/forego /usr/local/bin/
COPY --from=app /app/ /app/
COPY --chmod=0755 docker-entrypoint.sh /app/docker-entrypoint.sh
COPY --chmod=0755 healthcheck.sh /app/healthcheck.sh
COPY nginx.conf /etc/nginx/nginx.conf
RUN mv /app/network_internal.conf /etc/nginx/network_internal.conf

# DOCKER_GEN_VERSION: acme-companion tells a docker-gen container from an
# nginx-proxy one by this variable, as with upstream's image.
ENV NGINX_PROXY_VERSION=${NGINX_PROXY_VERSION}-hardened \
    DOCKER_GEN_VERSION=${DOCKER_GEN_VERSION} \
    DOCKER_HOST=unix:///tmp/docker.sock

LABEL org.opencontainers.image.title="hardened-nginx-proxy" \
      org.opencontainers.image.description="nginx-proxy ${NGINX_PROXY_VERSION} on the Docker Hardened Image for nginx" \
      org.opencontainers.image.source="https://github.com/overcookedpanda/hardened-images" \
      org.opencontainers.image.licenses="MIT"

# Runs as root, like upstream: docker-gen needs the Docker socket (root:docker,
# 0660 on the host) and nginx must read the private keys acme-companion writes
# as root:root 0600. nginx workers still drop to `nginx` (nginx.conf). See
# README.md for running it non-root.
WORKDIR /app
EXPOSE 80 443
# Healthy when the config is valid and nginx is serving; see healthcheck.sh
# (HTTP_PORT and ENABLE_PROXY_PROTOCOL aware, busybox only).
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
  CMD ["/app/healthcheck.sh"]
ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["forego", "start", "-r"]
