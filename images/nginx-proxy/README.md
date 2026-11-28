# hardened-nginx-proxy

A rebuild of [nginx-proxy](https://github.com/nginx-proxy/nginx-proxy)
(docker-gen writes the nginx config from container labels such as
`VIRTUAL_HOST`) on the Docker Hardened Image for nginx. It is a drop-in for
`nginxproxy/nginx-proxy:1.11.6-alpine`: same environment variables, same
volume paths, same labels.

```bash
docker pull ghcr.io/overcookedpanda/hardened-nginx-proxy:latest
```

Built, smoke-tested, scanned and published by
[`.github/workflows/nginx-proxy.yml`](../../.github/workflows/nginx-proxy.yml)
through the shared [build-scan-publish workflow](../../docs/pipeline.md). Tags:
`sha-<12>` for builds of a commit, `<YYYYMMDD>` for nightly rebuilds,
`1.11.6` for the upstream version it tracks, and `latest`.

## Switching from upstream

Change the image and recreate the container. Your certificates, `vhost.d`,
`conf.d` and `htpasswd` volumes carry over unchanged. Things to check:

- If you mounted your own `nginx.tmpl` to work around upstream's HTTP/2
  handling, drop it: the template here honours `ENABLE_HTTP2` (see below).
- If you rely on OCSP stapling, set `ENABLE_OCSP_STAPLING=true` (see below).
- The image has a `HEALTHCHECK`, so `docker ps` shows it as healthy and
  `depends_on: condition: service_healthy` works. A `healthcheck:` in your
  compose file still overrides it.
- Rolling back is the same in reverse: put the upstream image back.

## What's in it

| | upstream `1.11.6-alpine` | `hardened-nginx-proxy` |
|---|---|---|
| Base | `nginx:1.31.3-alpine` (full Alpine) | `dhi.io/nginx:1.31.10-alpine3.24` (nginx, musl, busybox) |
| nginx | 1.31.3 (affected by the HTTP/2 CVEs behind `ENABLE_HTTP2=false`) | 1.31.10 |
| docker-gen, forego | copied from upstream images | built from source with DHI Go 1.26 ([`tools/go.mod`](tools/go.mod)), libraries with fixed CVEs raised |
| bash, openssl, apk, curl | yes | no |
| Entrypoint | bash | the same logic in POSIX sh ([`docker-entrypoint.sh`](docker-entrypoint.sh)) |
| `nginx.tmpl` | upstream | upstream + [`patches/`](patches/) (the fallback server honours `ENABLE_HTTP2`; OCSP stapling is opt-in) |
| User | root, nginx workers as `nginx` | the same (workers are uid 65532) |
| `HEALTHCHECK` | none | [`healthcheck.sh`](healthcheck.sh) every 30 s: `nginx -t` plus any HTTP answer on `HTTP_PORT` (default 80), or the nginx master alive when `ENABLE_PROXY_PROTOCOL` is on |

### OCSP stapling is off by default

Upstream turns on `ssl_stapling` for every certificate that has a
`<host>.chain.pem`. Let's Encrypt certificates no longer carry an OCSP URL,
so nginx ignored it and logged `"ssl_stapling" ignored, no OCSP responder URL`
for every certificate on every reload. The template now staples only with
`ENABLE_OCSP_STAPLING=true`, for a certificate from a CA that still runs OCSP.

Everything nginx-proxy documents still applies: same env vars, same volume
paths (`/etc/nginx/certs`, `vhost.d`, `conf.d`, `htpasswd`,
`/usr/share/nginx/html`), the socket at `/tmp/docker.sock`, and
`DOCKER_GEN_VERSION` set so acme-companion recognises it. acme-companion's
reload, which execs `sh -c "/app/docker-entrypoint.sh /usr/local/bin/docker-gen …; /usr/sbin/nginx -s reload"`
in this container, works and is part of the smoke test.

### Why it still runs as root

docker-gen needs the Docker socket (`root:docker`, 0660 on the host), and
nginx must read the private keys acme-companion writes as `root:root` 0600.
You can run it non-root, but it needs both of these:

- `group_add:` with the host's docker group id on the nginx-proxy service, and
  `user: "65532:65532"`;
- `FILES_UID=65532` (and `FILES_GID`) on acme-companion, plus a one-time
  `chown` of any existing keys in the certificates volume.

Note that whoever holds the Docker socket is root on the host either way, so
the main gain from the hardened base is the much smaller attack surface, not
the uid.

## Bumping versions

- **DHI bases** (`dhi.io/golang`, `dhi.io/nginx`): Dependabot, weekly
  (needs `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` as Dependabot secrets).
- **docker-gen / forego and their libraries**: pinned in
  [`tools/go.mod`](tools/go.mod), which Dependabot (gomod) keeps current. That
  file also holds the security floors above what upstream pins. To move to a
  new docker-gen tag by hand, `cd tools && go get -tool
  github.com/nginx-proxy/docker-gen/cmd/docker-gen@<pseudo-version> && go mod
  tidy`, then set `DOCKER_GEN_VERSION` and `DOCKER_GEN_COMMIT` in the
  Dockerfile (the build fails if they disagree with go.mod). docker-gen's tags
  have no `v`, so Go needs the pseudo-version of the tag's commit:
  `curl -s https://proxy.golang.org/github.com/nginx-proxy/docker-gen/@v/<tag>.info`.
- **nginx-proxy** (template and app files): `./update-upstream.sh <tag>`, set
  `NGINX_PROXY_VERSION` to match, check the patch still applies (the build
  fails if not), and port any change in upstream's
  `app/docker-entrypoint.sh`.

Local builds need `docker login dhi.io` first, even though the images are free.
