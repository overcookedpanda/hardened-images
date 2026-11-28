# Third-party software

This repository's own files (workflows, Dockerfiles, scripts, docs) are under
the MIT license in [LICENSE](LICENSE). The images bundle or build other
projects, which keep their own licenses:

| Component | Where | License |
|---|---|---|
| nginx-proxy templates and app files | `images/nginx-proxy/upstream/` (vendored, see its `LICENSE`) | MIT |
| acme-companion scripts | `images/acme-companion/upstream/` (vendored, see its `LICENSE`) | MIT |
| docker-gen | built from source in both proxy images | MIT |
| forego | built from source in the nginx-proxy image | Apache-2.0 |
| acme.sh | downloaded and checksum-verified at build time | GPL-3.0 |
| MariaDB | installed from the MariaDB apt repository | GPL-2.0 |
| Apache Airflow | the official `apache/airflow` slim image, with packages from PyPI | Apache-2.0 |
| nginx | from the Docker Hardened Image base | BSD-2-Clause |
| Docker Hardened Images (`dhi.io`) | base and builder images | Apache-2.0 |

Published images contain these components. Their source is available from the
upstream projects linked in each image's README; the build recipes are here.
