# hardened-images

Drop-in, hardened rebuilds of a few self-hosting staples, and the GitHub
Actions pipeline that keeps them patched. Every image is rebuilt nightly,
smoke-tested, and published only if a Trivy scan finds no fixable
vulnerabilities above its threshold.

| Image | Drop-in for | What's different |
|---|---|---|
| [hardened-mariadb](images/mariadb/README.md) | `mariadb` | Ubuntu 24.04 + official MariaDB repo, fully upgraded every build, non-root, no setuid binaries |
| [hardened-nginx-proxy](images/nginx-proxy/README.md) | `nginxproxy/nginx-proxy:1.11.6-alpine` | On the Docker Hardened Image for nginx; no bash, openssl, apk or curl; docker-gen and forego built from source with current Go; HTTP/2 setting honoured; OCSP stapling opt-in |
| [hardened-acme-companion](images/acme-companion/README.md) | `nginxproxy/acme-companion:2.8.2` | Trimmed package set, acme.sh from a checksum-verified tarball, docker-gen built from source; tested end to end against Let's Encrypt's Pebble CA |

```bash
docker pull ghcr.io/overcookedpanda/hardened-mariadb:12.3
docker pull ghcr.io/overcookedpanda/hardened-nginx-proxy:latest
docker pull ghcr.io/overcookedpanda/hardened-acme-companion:latest
```

## Tags

| Tag | Meaning |
|---|---|
| `latest` | Moves on every publish. Every image it can point at passed the gate. |
| `<upstream version>` | e.g. `12.3`, `1.11.6`, `2.8.2`. Moves with patch rebuilds of that version. |
| `sha-<12 chars>` | The build of one commit. Immutable. |
| `<YYYYMMDD>` | A nightly rebuild against newer base packages. Immutable. |

Pin a `sha-*` or date tag (or a digest) when you need an image held still.

## The pipeline

All three images go through one reusable workflow,
[`build-scan-publish.yml`](.github/workflows/build-scan-publish.yml):

```
build -> smoke test -> Trivy report (all severities, kept 30 days)
      -> Trivy gate (fixable findings only; OS and language packages
                     get separate thresholds)
      -> diff against the published image (packages and CVEs)
      -> push      only if the gate passed; nightly runs only if packages changed
      -> alert     only when the rebuild resolved CVEs
      -> prune old versions, then verify the published tags survived
```

Pull requests build, smoke-test and scan, and never publish. Use it for your
own images too: see [docs/using-the-workflow.md](docs/using-the-workflow.md),
and [docs/pipeline.md](docs/pipeline.md) for why each step is there.

## Running the workflows in your copy

Everything is gated on a repository variable so that a private fork spends no
Actions minutes:

1. **Settings → Secrets and variables → Actions → Variables**: add
   `PIPELINES_ENABLED` = `true`. Until then only manual runs do anything.
2. **Secrets** (Actions, and the same two under Dependabot):
   `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`, a Docker account and access
   token. The nginx-proxy image and the Go builder pull from `dhi.io`, which
   needs a login even for the free Docker Hardened Images.
3. Optional: `ALERTS_DISCORD_WEBHOOK` for alerts.
4. Publishing to GHCR uses the built-in `GITHUB_TOKEN`; nothing to set up.
   After the first publish, make each package public under **Packages →
   Package settings** if the repository is public.

## License

MIT for this repository's own files; see [LICENSE](LICENSE). The images
contain software under other licenses (GPL for MariaDB and acme.sh); see
[THIRD_PARTY.md](THIRD_PARTY.md).
