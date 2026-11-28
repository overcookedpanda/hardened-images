# Using the workflow for your own images

Call [`build-scan-publish.yml`](../.github/workflows/build-scan-publish.yml)
from a workflow in your repository. Pin it to a commit SHA, as you would an
action.

```yaml
name: my-app image

on:
  push:
    branches: [ main ]
    paths: [ 'docker/my-app/**' ]
  pull_request:
    paths: [ 'docker/my-app/**' ]
  schedule:
    - cron: '0 4 * * *'   # nightly, for base-image fixes
  workflow_dispatch:

permissions: {}

jobs:
  image:
    permissions:
      contents: read
      packages: write
    uses: overcookedpanda/hardened-images/.github/workflows/build-scan-publish.yml@<commit-sha>
    with:
      image-name: my-app
      context: docker/my-app
      smoke-test: docker/my-app/smoke-test.sh
    secrets:
      discord-webhook: ${{ secrets.ALERTS_DISCORD_WEBHOOK }}
```

That publishes `ghcr.io/<your-account>/my-app` with the built-in
`GITHUB_TOKEN`.

## Inputs

| Input | Default | |
|---|---|---|
| `image-name` | (required) | Name without registry or tag |
| `context` | (required) | Build context |
| `dockerfile` | `<context>/Dockerfile` | |
| `build-args` | | One `KEY=VALUE` per line |
| `platform` | `linux/amd64` | One platform (see pipeline.md) |
| `registry` | `ghcr.io` | `docker.io` works too |
| `namespace` | repository owner | |
| `smoke-test` | | Script run with `IMAGE` set to the candidate |
| `trivyignore` | | Accepted findings |
| `gate-os-severity` | `CRITICAL,HIGH,MEDIUM` | Empty disables the OS gate |
| `gate-library-severity` | `CRITICAL,HIGH` | Empty disables the library gate |
| `publish` | `true` | `false`: build and scan only. Pull requests never publish. |
| `tag-latest` | `true` | |
| `extra-tags` | | Space-separated |
| `skip-unchanged-nightly` | `true` | |
| `dhi-login` | `false` | Log in to `dhi.io` first |
| `prune` | `true` | GHCR only |
| `keep-versions` | `10` | |
| `keep-untagged` | `3` | Keep a floor; see pipeline.md |

## Secrets

| Secret | When |
|---|---|
| `registry-username`, `registry-password` | Any registry other than GHCR |
| `dhi-username`, `dhi-token` | With `dhi-login: true` |
| `discord-webhook` | Optional alerts |

## Outputs

`image`, `digest` (empty when nothing was published), `published`
(`'true'`/`'false'`) and `resolved-count`.

## Writing a smoke test

The script gets `IMAGE` and must exit non-zero if anything is wrong. Check
that the image works, not that it starts: send it a request, run a query,
read a config it generates. Then check the hardening you care about, so a
base-image change can't quietly undo it: the user it runs as, tools that
must be absent, setuid binaries. A `docker stop` timing check catches a PID 1
that ignores SIGTERM. The smoke tests in `images/` are examples.

## Docker Hardened Images

`dhi.io` needs a login even for the free images: a Docker account and an
access token as `dhi-username` and `dhi-token`. Dependabot reads its own
secret store, so if Dependabot should update your `FROM dhi.io/...` lines,
add the same two secrets there and a `docker-registry` entry for `dhi.io` in
`dependabot.yml` (see this repository's).

Build stages use the `-dev` variants (shell, package manager); the runtime
stage uses the plain variant, which has no shell or package manager and runs
as a non-root user. Copy in what the runtime needs (`dumb-init`, a static
binary) from a `-dev` stage.
