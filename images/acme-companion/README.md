# hardened-acme-companion

A rebuild of [acme-companion](https://github.com/nginx-proxy/acme-companion),
which issues and renews the Let's Encrypt certificates nginx-proxy serves. It
is a drop-in for `nginxproxy/acme-companion:2.8.2`, and works with upstream
nginx-proxy as well as [hardened-nginx-proxy](../nginx-proxy/README.md).

```bash
docker pull ghcr.io/overcookedpanda/hardened-acme-companion:latest
```

This is usually the most privileged container on a host: it holds the Docker
socket (effectively root) and writes every TLS private key. That is why it
gets the full build, scan and nightly-patch pipeline.

Built, smoke-tested, scanned and published by
[`.github/workflows/acme-companion.yml`](../../.github/workflows/acme-companion.yml)
through the shared [build-scan-publish workflow](../../docs/pipeline.md). Tags:
`sha-<12>`, `<YYYYMMDD>` for nightly rebuilds, `2.8.2` for the upstream
version it tracks, and `latest`.

## Switching from upstream

Change the image and recreate the container. Both images use the same volume
layout, so ACME accounts and certificates carry over either way. If you use
DNS-01, standalone mode, SSH deploy hooks or internationalised domain names,
read "What the trimmed packages mean" first.

## What's in it

| | upstream `2.8.2` | `hardened-acme-companion` |
|---|---|---|
| Base | `alpine:3.24.1` | `alpine:3.24`, pinned by digest, `apk upgrade` on every build |
| Packages | bash, bind-tools, coreutils, curl, jq, libidn, oathtool, openssh-client, openssl, sed, socat, tar, tzdata | bash, coreutils, curl, jq, openssl, sed, tar, tzdata |
| acme.sh | 3.1.4, `git clone` at build time | 3.1.4, release tarball checked against its SHA-256 |
| docker-gen | copied from `nginxproxy/docker-gen:0.17.2` | 0.17.2 built from source with DHI Go 1.26, from [`../nginx-proxy/tools/go.mod`](../nginx-proxy/tools/go.mod) (shared with the nginx-proxy image, security floors included) |
| Scripts (`/app`) | upstream `app/` at v2.8.2 | the same files, vendored in [`upstream/`](upstream/) |
| User | root | root (it needs the socket and writes root-only keys) |

Size: about 38 MB, against upstream's 48 MB.

### Why not a Docker Hardened Image

acme-companion is bash scripts around acme.sh, and acme.sh needs bash, curl,
openssl and coreutils. A shell-less base can't run it. So the hardening here
is a smaller package set, pinned sources and the Trivy gate (fixable
CRITICAL/HIGH/MEDIUM in Alpine packages, fixable CRITICAL/HIGH in docker-gen),
with nightly rebuilds so fixes land without anyone touching the Dockerfile.

### What the trimmed packages mean

The usual setup validates certificates with HTTP-01 through nginx-proxy,
which needs none of what was dropped:

- `bind-tools` and `oathtool`: DNS-01 with acme.sh's DNS API scripts;
- `socat`: acme.sh's standalone mode;
- `openssh-client`: acme.sh's SSH deploy hook;
- `libidn`: internationalised domain names.

Moving to DNS-01, standalone or IDN domains means adding the package back.

## Smoke test

The pipeline issues a real certificate end to end, against
[Pebble](https://github.com/letsencrypt/pebble) (Let's Encrypt's test CA):
nginx-proxy (upstream by default, so the test also proves this image is a
drop-in), found by its acme-companion label, serves the HTTP-01 challenge; Pebble validates it through
pebble-challtestsrv's DNS; acme-companion writes the certificate; and
nginx-proxy then serves it. It also checks that the dropped tools are gone,
that acme.sh and docker-gen are the pinned versions, and that `docker stop`
is handled well inside 10 s. The test is [`smoke-test.sh`](smoke-test.sh);
[`smoke/pebble-config.json`](smoke/pebble-config.json) is upstream's own
test config.

## Bumping versions

- **Alpine base and the DHI Go builder**: Dependabot, weekly.
- **docker-gen**: pinned in `../nginx-proxy/tools/go.mod` with the nginx-proxy image.
  A bump also needs `DOCKER_GEN_VERSION` and `DOCKER_GEN_COMMIT` here; the
  build fails if they disagree with go.mod.
- **acme-companion** (the scripts): `./update-upstream.sh <tag>`, set
  `ACME_COMPANION_VERSION` to match, and check upstream's Dockerfile at that
  tag for a new `ACMESH_VERSION` or package.
- **acme.sh**: set `ACMESH_VERSION` and `ACMESH_SHA256`
  (`curl -fsSL https://github.com/acmesh-official/acme.sh/archive/refs/tags/<v>.tar.gz | sha256sum`).
  Prefer the version upstream acme-companion's release ships with: its
  scripts are tested against it.

Local builds need `docker login dhi.io` first (the Go builder), and the
build context is `images/`:

```bash
docker build -f images/acme-companion/Dockerfile images
```
