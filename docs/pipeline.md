# How the pipeline works, and why

[`build-scan-publish.yml`](../.github/workflows/build-scan-publish.yml) is a
reusable workflow: one image per call. These notes explain the choices in it,
most of which came from something going wrong.

## The image that is pushed is the image that was scanned

The image is built once, loaded into the runner's Docker, smoke-tested,
scanned, and only then tagged and pushed. Nothing is rebuilt between the scan
and the push. That is also why the workflow builds a single platform: a
multi-platform build can't be loaded and scanned locally before it is pushed.

## The gate blocks only on findings you can act on

The gate runs Trivy with `--ignore-unfixed`. A finding with a fix available
means the rebuild should already have pulled the fix in, so a hit is a real
signal: a pinned version, a held-back package, or a vendored binary built with
an old toolchain. A finding with no fix yet would block every build until
upstream ships one, so it goes to the report instead.

OS packages and language packages get separate thresholds
(`gate-os-severity`, default CRITICAL/HIGH/MEDIUM; `gate-library-severity`,
default CRITICAL/HIGH). A base image can be held to MEDIUM. A Go binary's
standard library often can't, until the next Go release.

Narrowing the OS gate to CRITICAL/HIGH is tempting when it gets noisy. That
exact setting once let 52 fixable MEDIUMs through on one image.

Accepted findings go in a `.trivyignore` with a reason and a date, and only
for a finding nothing in the repository can fix.

**Nothing that can fail goes above the gate**, other than the build and the
smoke test. An earlier version uploaded SARIF before the gate; the upload hit
a permission error, which skipped the gate and the publish entirely.

## The report, the gate and the diff use the same Trivy and the same DB

The report step installs Trivy and downloads its vulnerability DB into a cache
directory in the workspace. The gate and the diff call the same binary with
`--skip-db-update` against that cache. Different Trivy versions disagree:
0.64 and 0.70 differed by eight findings on an identical image. Different DB
downloads can disagree too, and a failed second download used to kill the
diff step with no output.

## Nightly rebuilds don't publish no-ops

The nightly run exists to pick up base-image and package fixes. But
`apt-get update` and `apk upgrade` rewrite package indexes on every build, so
each rebuild has a new layer digest even when nothing changed. Publishing all
of those would push a new version every night, and with a 10-version prune
window, a week and a half of history would be gone.

So on scheduled runs the workflow lists every package in the candidate and in
the published `latest` (from Trivy, which also sees vendored binaries and
works on images with no package manager) and skips the push when the lists
match. Pushes and manual runs always publish: a changed entrypoint script
changes the image without changing a package.

## Alerts fire only when CVEs were resolved

A new image is not by itself a reason to restart a database. The diff compares
CVE IDs between the candidate and the published image (per CVE, not per
package row, so one CVE in seven util-linux packages is one line), and the
alert fires only when the new image resolves something. Every alert carries a
concrete reason to pull. Its colour follows the highest resolved severity.

## Tags

- Builds of a commit get `sha-<12>`.
- Nightly rebuilds get `<YYYYMMDD>`. They rebuild the same commit against
  newer packages, so reusing `sha-<commit>` would overwrite it daily and stop
  it meaning "the build of that commit".
- `latest` and any `extra-tags` move on every publish.

## Pruning, and the two traps in it

On GHCR, the workflow prunes untagged versions (leftovers from retagging)
down to `keep-untagged`, then all versions down to `keep-versions`. Both keep
the newest N, and the image just pushed is the newest. Two traps in
`actions/delete-package-versions`:

- The packages API can list a version pushed seconds ago **with no tags
  yet**. With `keep-untagged: 0`, the untagged prune then deletes the image
  it just published, `latest` included. That happened. Keep a floor.
- `ignore-versions` matches the version *name*, which for a container is its
  digest, not its tag. `^latest$` never matches anything, so it protects
  nothing and isn't used.

## Verify after pruning

The last step reads each pushed tag back from the registry and compares the
digest. A missing or wrong tag is re-pushed from the local image (its layers
are still on the runner); only if that fails too does the step fail and alert.
A host that tracks `latest` would otherwise fail its next pull.

## Smoke tests

A scan says nothing about whether the image still works. Each image has a
`smoke-test.sh` that runs it for real and checks its hardening:

- **mariadb**: initialises, creates the user and database, accepts a TCP
  write and read, goes healthy, runs as mysql, has no setuid binaries, shuts
  down cleanly on SIGTERM.
- **nginx-proxy**: docker-gen picks up a backend by `VIRTUAL_HOST` and drops
  it when it goes away; the HTTP/2 patch holds; acme-companion's reload
  command works; no bash, openssl, apk or curl.
- **acme-companion**: issues a real certificate from Pebble over HTTP-01
  through nginx-proxy, which then serves it; dropped tools are gone; acme.sh
  and docker-gen are the pinned versions.

All three check that `docker stop` finishes well inside the 10 second kill,
which catches a PID 1 that ignores SIGTERM.

## Supply chain

- Every action is pinned to a full commit SHA, with the version in a comment.
  Dependabot updates both.
- Go tools are built from source with pinned modules (`tools/go.mod`, with
  `go.sum`), rather than copied out of other images.
- acme.sh comes from a release tarball checked against its SHA-256.
- Base images are pulled fresh on every build (`--pull`).

## Private repositories

On a private repository, Code Scanning needs GitHub Advanced Security, and
`github/codeql-action/upload-sarif` fails without it, so the report is kept as
a build artifact instead. On a public repository you can add a SARIF upload
after the gate (with `security-events: write`).
