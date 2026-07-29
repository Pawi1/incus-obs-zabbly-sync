# incus-obs-zabbly-sync

Scripts that treat [zabbly/incus](https://github.com/zabbly/incus) (Stéphane
Graber's Incus packaging repo) as the source of truth for which upstream
[lxc/incus](https://github.com/lxc/incus) tag and cherry-picked fixes an
openSUSE Build Service `incus` package should track, per branch
(`stable`, `lts-6.0`, `lts-7.0`, `daily`).

Only `INCUS_TAG` and the ordered `git cherry-pick` list are consumed from
zabbly's `.github/workflows/builds.yml` — not zabbly's full multi-component
`/opt/incus` build. The OBS package keeps building from the official
`linuxcontainers.org` release tarball against system libs, with zabbly's
cherry-picks applied as numbered `Patch:` entries on top.

## Scripts

- **`extract_zabbly.py`** — reads a branch's `builds.yml` (local clone via
  `--repo`, or remote) and extracts `INCUS_TAG` + the ordered cherry-pick
  list, scoped to the `cd /build/incus` build step.
- **`fetch_patches.py`** — fetches each cherry-picked commit as a patch file
  (prefers `gh api` for auth, falls back to the public `.patch` URL) and
  writes a `manifest.json`.
- **`update_spec.py`** — bumps `Version:` and (re)writes a marker-delimited
  `Patch:` block in `incus.spec`; idempotent, safe to re-run after zabbly
  rebases its cherry-pick list. Does not touch `%prep` — relies on
  `%autosetup -p1` already being in the spec.
- **`auto_update.sh`** — unattended wrapper: checks for a new `INCUS_TAG`,
  runs the three scripts above into a scratch copy of the package checkout,
  registers the file changes with `osc`, and **only promotes to the live
  checkout after a real local `osc build` passes**. Never auto-commits unless
  `--auto-commit` is passed explicitly. Needs to run somewhere with `osc`
  configured (a real host/server, e.g. via cron) — not a sandboxed agent
  environment.
- **`project-meta/`** — example/reference `_meta` XML used to create and
  configure the `home:pawil:incus:<branch>` projects and packages (repos,
  architectures, publish flags).

## Requirements

- Python 3, stdlib only (no pip installs needed).
- `osc`, configured and authenticated, for anything that touches OBS.
- `gh` CLI (optional but recommended) for `fetch_patches.py`, to avoid
  GitHub's anonymous rate limits when fetching many patches.

## Known upstream gotchas (why the build gate matters)

Neither of these is detectable from `builds.yml` alone — they only surface
once you actually try to build, which is exactly why `auto_update.sh` never
promotes/commits without a passing local `osc build` first:

1. **Release tarball directory naming.** Upstream's tarball drops a literal
   trailing `.0` patch component (`v7.2.0` → `incus-7.2/`) but keeps
   non-zero patch versions in full (`v7.0.1` → `incus-7.0.1/`,
   `v6.0.6` → `incus-6.0.6/`); the old flat-number scheme is untouched
   either way (`v6.23` → `incus-6.23/`). Handled via:
   ```
   %global archive_version %(echo %{version} | sed -E 's/\.0$//')
   %autosetup -n %{name}-%{archive_version} -p1
   ```
2. **`lxd-to-incus` removed upstream** between `v6.23.0` and `v7.0.x`/`v7.2.0`
   (still present as of `v7.0.1` and `v6.0.6`, gone by `v7.2.0`). If a spec
   references `%{_sbindir}/lxd-to-incus` in `%files` and upstream no longer
   builds it, packaging fails with `File not found`. Check
   `gh api repos/lxc/incus/contents/cmd -f ref=<tag>` before assuming it's
   still there.

## Not handled here

- **`daily`** (`INCUS_TAG: main`) has no versioned release tarball to
  download — it needs a fundamentally different sourcing mechanism (e.g. a
  `tar_scm`-style git snapshot with a `%{version}~git%{shortcommit}`-style
  version string), not this tarball+patches model. Deliberately out of scope
  for now.
- **Fedora** as a build target: the spec has real SUSE-specific coupling
  (`sysuser-tools`/`%sysusers_generate_pre`, `golang-packaging`,
  `lxd-ovmf-setup-<arch>`, `pkgconfig(cowsql)` availability unverified on
  Fedora) — porting is a real project, not a repository-path addition.
- **`openSUSE:Leap:15.6`**: EOL, and its repos only carry Go up to 1.21
  (need `go >= 1.24.7`), so it's excluded as a build target regardless.
