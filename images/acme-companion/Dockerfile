# syntax=docker/dockerfile:1
#
# hardened acme-companion: acme-companion (Let's Encrypt certificates for
# nginx-proxy) rebuilt as a drop-in for nginxproxy/acme-companion:2.8.2, with a
# trimmed package set, docker-gen built from source and packages upgraded on
# every build.
#
# Built, smoke-tested (a real certificate from a Pebble test CA), scanned and
# published by .github/workflows/acme-companion.yml (via
# build-scan-publish.yml), as ghcr.io/<owner>/hardened-acme-companion. See
# README.md for what differs from upstream and why the base is plain Alpine
# rather than a DHI image.
#
# Build context is images/, not this directory: docker-gen comes from the same
# pins as the nginx-proxy image (nginx-proxy/tools/go.mod), so both images
# move together.
#   docker build -f images/acme-companion/Dockerfile images
# Pulling from dhi.io (the Go builder) needs `docker login dhi.io`.

ARG ACME_COMPANION_VERSION=v2.8.2
ARG ACMESH_VERSION=3.1.4
ARG ACMESH_SHA256=e5f8e187bbf5251e0cd8891f2622daab9850366bd17bea9f92c2fe2ee091fd32
ARG DOCKER_GEN_VERSION=0.17.2
ARG DOCKER_GEN_COMMIT=497e50d07d3a

# ---------------------------------------------------------------------------
# docker-gen, built from source with the current Go toolchain from the same
# go.mod as the nginx-proxy image (security floors included), instead of copied out
# of nginxproxy/docker-gen.
# ---------------------------------------------------------------------------
FROM dhi.io/golang:1.27-alpine3.24-dev AS build
ARG DOCKER_GEN_VERSION
ARG DOCKER_GEN_COMMIT
ENV CGO_ENABLED=0 GOFLAGS="-trimpath -mod=readonly" GOTOOLCHAIN=local
WORKDIR /src
COPY nginx-proxy/tools/go.mod nginx-proxy/tools/go.sum ./
RUN go mod download
RUN set -e; \
    gen="$(go list -m -f '{{.Version}}' github.com/nginx-proxy/docker-gen)"; \
    case "$gen" in *"-${DOCKER_GEN_COMMIT}") ;; \
        *) echo "nginx-proxy/tools/go.mod has docker-gen $gen, not commit ${DOCKER_GEN_COMMIT} (${DOCKER_GEN_VERSION})" >&2; exit 1 ;; \
    esac; \
    go build -ldflags "-s -w -X main.buildVersion=${DOCKER_GEN_VERSION}" -o /out/ \
        github.com/nginx-proxy/docker-gen/cmd/docker-gen; \
    /out/docker-gen -version

# ---------------------------------------------------------------------------
# acme.sh at a pinned release, checked against its tarball's SHA-256.
# ---------------------------------------------------------------------------
FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS acmesh
ARG ACMESH_VERSION
ARG ACMESH_SHA256
ADD --checksum=sha256:${ACMESH_SHA256} \
    https://github.com/acmesh-official/acme.sh/archive/refs/tags/${ACMESH_VERSION}.tar.gz /acme.sh.tar.gz
RUN mkdir /src && tar -xzf /acme.sh.tar.gz -C /src --strip-components=1

# ---------------------------------------------------------------------------
# Runtime. acme-companion is bash scripts around acme.sh, which needs bash,
# curl, openssl and coreutils, so a shell-less hardened base doesn't fit.
# Plain Alpine instead, with only what the scripts use: upstream's DNS tools
# (bind-tools), oathtool, openssh-client, socat and libidn serve DNS-01 APIs,
# standalone mode and SSH deploy hooks, none of which the HTTP-01 flow through
# nginx-proxy needs. `apk upgrade` plus the nightly rebuild keep packages
# patched; the pipeline's Trivy gate fails on any fixable CRITICAL/HIGH/MEDIUM.
# ---------------------------------------------------------------------------
FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf
ARG ACME_COMPANION_VERSION
ARG ACMESH_VERSION
ARG DOCKER_GEN_VERSION

RUN apk upgrade --no-cache \
    && apk add --no-cache bash coreutils curl jq openssl sed tar tzdata

COPY --from=build /out/docker-gen /usr/local/bin/docker-gen

# Same install as upstream's install_acme.sh: acme.sh in /app, its config in
# /etc/acme.sh/default, no cron and no self-upgrade (the image pins it).
RUN --mount=type=bind,from=acmesh,source=/src,target=/src,rw \
    cd /src \
    && ./acme.sh --install --nocron --auto-upgrade 0 \
        --home /app --config-home /etc/acme.sh/default \
    && /app/acme.sh --version

COPY --chmod=0755 acme-companion/upstream/ /app/
RUN chmod 0644 /app/LICENSE /app/dhparam.pem.default /app/nginx_location.conf \
    && chmod 0755 /app/dhparam && chmod 0644 /app/dhparam/*.pem

ENV ACMESH_VERSION=${ACMESH_VERSION} \
    COMPANION_VERSION=${ACME_COMPANION_VERSION}-hardened \
    DOCKER_GEN_VERSION=${DOCKER_GEN_VERSION} \
    DOCKER_HOST=unix:///var/run/docker.sock \
    PATH=${PATH}:/app

LABEL org.opencontainers.image.title="hardened-acme-companion" \
      org.opencontainers.image.description="acme-companion ${ACME_COMPANION_VERSION} with acme.sh ${ACMESH_VERSION}, trimmed and scanned" \
      org.opencontainers.image.source="https://github.com/overcookedpanda/hardened-images" \
      org.opencontainers.image.licenses="MIT"

# Runs as root, like upstream: it reads the Docker socket and writes the
# private keys nginx-proxy serves (root:root 0600).
WORKDIR /app
ENTRYPOINT ["/bin/bash", "/app/entrypoint.sh"]
CMD ["/bin/bash", "/app/start.sh"]
