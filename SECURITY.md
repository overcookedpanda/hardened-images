# Security

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub: **Security → Report a
vulnerability** on this repository. Please don't open a public issue for a
security problem.

## What's in scope

- The build recipes and workflows in this repository.
- A published image that ships a **fixable** vulnerability the pipeline's
  Trivy gate should have caught.

Vulnerabilities in the upstream software itself (MariaDB, nginx, acme.sh,
docker-gen, ...) belong with those projects. Once upstream ships a fix, the
nightly rebuild picks it up.

## How images stay patched

Every image is rebuilt nightly. A rebuild is published only if it passes the
Trivy gate (no fixable findings above the configured severity), and only if
its package set changed. See [docs/pipeline.md](docs/pipeline.md).
