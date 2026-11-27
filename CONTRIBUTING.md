# Contributing

Issues and pull requests are welcome.

- **Commits and PR titles** follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `chore:`, `docs:` ...). PRs are squash-merged, so the PR
  title becomes the commit message.
- **Actions** are pinned to a full commit SHA with the version in a comment.
  Dependabot keeps them current.
- **A new image** goes in `images/<name>/` with a Dockerfile, a
  `smoke-test.sh` that fails if the image is broken or its hardening slipped,
  a README saying what differs from upstream, and a small caller workflow in
  `.github/workflows/<name>.yml` (copy an existing one).
- **Accepting a finding** in a `.trivyignore` needs a comment with the reason
  and a date, and only for a finding nothing in this repository can fix.

Run the linters locally before pushing:

```bash
actionlint
shellcheck --severity=warning $(git ls-files '*.sh' | grep -v /upstream/)
```
