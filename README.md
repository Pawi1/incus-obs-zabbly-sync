# incus-obs-zabbly-sync

[![build result](https://build.opensuse.org/projects/home:pawil:incus:stable/packages/incus/badge.svg?type=default)](https://build.opensuse.org/package/show/home:pawil:incus:stable/incus)

Keeps an openSUSE Build Service `incus` package in sync with [zabbly/incus](https://github.com/zabbly/incus), Stéphane Graber's packaging repo. Zabbly is treated as the source of truth for which [lxc/incus](https://github.com/lxc/incus) tag and which upstream fixes get cherry-picked, per branch (`stable`, `lts-6.0`, `lts-7.0`, `daily`).

We don't pull in zabbly's whole multi-component `/opt/incus` build, just `INCUS_TAG` and the ordered list of `git cherry-pick` commits from `.github/workflows/builds.yml`. The OBS package still builds from the official `linuxcontainers.org` tarball against system libs, with the cherry-picks applied on top as numbered `Patch:` entries.

## Scripts

`extract_zabbly.py` reads a branch's `builds.yml` (pass `--repo` for a local clone, or it fetches remotely) and pulls out `INCUS_TAG` plus the cherry-pick list. It only looks inside the `cd /build/incus` step, so cherry-picks for other components can't leak in.

`fetch_patches.py` takes that list and downloads each commit as a patch file. Uses `gh api` if it's around (avoids GitHub's anonymous rate limit), otherwise falls back to the public `.patch` URL. Writes a `manifest.json` alongside the patches.

`update_spec.py` bumps `Version:` and rewrites a marked block of `Patch:` lines in `incus.spec`. Safe to run again and again — if zabbly rebases its cherry-pick list, the old block just gets replaced instead of piling up. Doesn't touch `%prep`, since the spec already uses `%autosetup -p1`.

`auto_update.sh` strings the three together for unattended runs: checks if `INCUS_TAG` moved, builds everything in a scratch copy, and only touches the live checkout if a real local `osc build` actually passes. Won't commit unless you pass `--auto-commit`. Needs `osc` configured on whatever box runs it (cron, presumably) — it can't run inside a sandboxed agent that has no server credentials, which is why this exists as a standalone script rather than something run automatically here.

`project-meta/` has the `_meta` XML used to set up each `home:pawil:incus:<branch>` project (repos, arches, publish flags). Mostly there as a reference for adding another branch later.

## Requirements

Python 3, stdlib only, nothing to `pip install`. `osc`, configured, for anything that touches OBS. `gh` if you want `fetch_patches.py` to not get rate-limited.

## Two upstream gotchas that bit us

Both of these only show up once you actually try to build — `builds.yml` gives no hint either is coming. That's the whole reason `auto_update.sh` insists on a real local build before touching the live checkout.

**Tarball directory naming isn't consistent.** A release tarball drops a literal trailing `.0` (`v7.2.0` → `incus-7.2/`) but keeps non-zero patch versions in full (`v7.0.1` → `incus-7.0.1/`, `v6.0.6` → `incus-6.0.6/`). The old flat-number releases are untouched either way (`v6.23` → `incus-6.23/`). Fixed with:

```
%global archive_version %(echo %{version} | sed -E 's/\.0$//')
%autosetup -n %{name}-%{archive_version} -p1
```

**`lxd-to-incus` got removed upstream**, somewhere between `v6.23.0` and `v7.2.0` (still there in `v7.0.1` and `v6.0.6`, gone by `v7.2.0`). If the spec still lists `%{_sbindir}/lxd-to-incus` in `%files`, packaging fails with a plain "File not found" the moment upstream stops building it. Worth checking `gh api repos/lxc/incus/contents/cmd -f ref=<tag>` against the previous version before assuming it's still there.

## What this doesn't cover

`daily` tracks `main`, which has no release tarball at all — it'd need a git-snapshot sourcing setup instead (`tar_scm`, some `%{version}~git%{shortcommit}` version string). Different enough problem that it isn't attempted here yet.

Fedora as a build target is its own project, not a repo-path addition. The spec leans on SUSE-only macros (`sysuser-tools`, `golang-packaging`) and packages (`lxd-ovmf-setup-<arch>`), and it's not clear `cowsql` is even packaged for Fedora at all.

`openSUSE:Leap:15.6` is out too — it's EOL, and its repos only go up to Go 1.21 when the spec wants 1.24.7+.
