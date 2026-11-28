"""Write Airflow's constraints with every installed package pinned as installed.

Usage: python merge-constraints.py UPSTREAM_CONSTRAINTS > constraints.txt

Each `name==version` line of the upstream file keeps its place; a package that
is installed gets its installed version instead. Installed packages the
upstream file doesn't list (apache-airflow itself, for one) are appended.
The installer tools (pip, setuptools, wheel) are left out: they belong to the
base Python, and pinning them would only stop a derived image upgrading them.
"""

import re
import sys
from importlib.metadata import distributions


def norm(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


TOOLS = {"pip", "setuptools", "wheel"}

installed = {}
for dist in distributions():
    name = dist.metadata["Name"]
    if name and norm(name) not in TOOLS:
        installed.setdefault(norm(name), (name, dist.version))

out = []
seen = set()
with open(sys.argv[1], encoding="utf-8") as upstream:
    for line in upstream:
        line = line.rstrip("\n")
        m = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==(\S+)", line)
        if not m:
            out.append(line)
            continue
        key = norm(m.group(1))
        seen.add(key)
        if key in installed:
            out.append(f"{m.group(1)}=={installed[key][1]}")
        else:
            out.append(line)

extra = sorted(k for k in installed if k not in seen)
if extra:
    out.append("#")
    out.append("# Installed in hardened-airflow, not in the upstream file:")
    out.extend(f"{installed[k][0]}=={installed[k][1]}" for k in extra)

print("\n".join(out))
