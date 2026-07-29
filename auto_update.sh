#!/usr/bin/env bash
# auto_update.sh -- unattended zabbly -> OBS incus.spec update, validated by a
# real local `osc build` before anything touches the live checkout.
#
# This has to run somewhere with `osc` installed and configured (your own
# host/server, e.g. via cron) -- it cannot run where Claude does, since osc
# there has no server credentials. Never auto-commits unless --auto-commit is
# passed explicitly; by default it stops after a validated local build and
# leaves the live checkout staged (added/removed, not committed) for you to
# review with `osc status` / `osc diff` and commit yourself.
#
# What this does NOT catch automatically: things like the archive_version
# directory-name mismatch or a removed upstream binary (lxd-to-incus) that we
# hit going 6.23 -> 7.2.0 -- those needed a one-time manual spec fix. If a
# future jump hits something similar, THIS SCRIPT'S BUILD STEP WILL FAIL AND
# STOP (nothing gets promoted or committed) -- that's the safety net, not a
# bug. You'll need to fix the spec by hand once, the same way, then it's
# unattended again from the next run.
#
# Usage:
#   auto_update.sh --branch stable \
#                   --checkout ~/obs/home:pawil:incus:stable/incus \
#                   --zabbly-repo ~/obs/incus \
#                   --scripts-dir ~/obs/scripts \
#                   --author "Name <email>" \
#                   [--repo openSUSE_Tumbleweed] [--arch x86_64] \
#                   [--upstream lxc/incus] [--auto-commit]
#
# Exit codes: 0 = nothing to do, or committed/staged successfully.
#             1 = build failed (scratch checkout left in place for inspection).
#             2 = bad arguments / preconditions not met.

set -euo pipefail

REPO="openSUSE_Tumbleweed"
ARCH="x86_64"
UPSTREAM="lxc/incus"
AUTO_COMMIT=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	--branch) BRANCH="$2"; shift 2 ;;
	--checkout) CHECKOUT="$2"; shift 2 ;;
	--zabbly-repo) ZABBLY_REPO="$2"; shift 2 ;;
	--scripts-dir) SCRIPTS_DIR="$2"; shift 2 ;;
	--author) AUTHOR="$2"; shift 2 ;;
	--repo) REPO="$2"; shift 2 ;;
	--arch) ARCH="$2"; shift 2 ;;
	--upstream) UPSTREAM="$2"; shift 2 ;;
	--auto-commit) AUTO_COMMIT=1; shift ;;
	*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac
done

: "${BRANCH:?--branch is required (stable|daily|lts-6.0|lts-7.0)}"
: "${CHECKOUT:?--checkout is required (path to the live osc package checkout)}"
: "${ZABBLY_REPO:?--zabbly-repo is required (local zabbly/incus clone)}"
: "${SCRIPTS_DIR:?--scripts-dir is required (dir with extract_zabbly.py etc.)}"
: "${AUTHOR:?--author is required, e.g. 'Name <email>' -- used for the unattended .changes entry}"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

CHECKOUT=$(realpath "$CHECKOUT")
cd "$CHECKOUT"

log "checking working copy is clean before touching anything"
if [[ -n "$(osc status)" ]]; then
	echo "error: $CHECKOUT has uncommitted changes, refusing to touch it" >&2
	osc status >&2
	exit 2
fi

log "updating checkout from server"
osc up >/dev/null

CURRENT_VERSION=$(grep -m1 '^Version:' incus.spec | awk '{print $2}')
log "currently packaged version: $CURRENT_VERSION"

TMPJSON=$(mktemp)
trap 'rm -f "$TMPJSON"' EXIT

python3 "$SCRIPTS_DIR/extract_zabbly.py" --branch "$BRANCH" --repo "$ZABBLY_REPO" -o "$TMPJSON"

NEW_TAG=$(python3 -c "import json; print(json.load(open('$TMPJSON'))['tag'])")
NEW_VERSION="${NEW_TAG#v}"

if [[ "$NEW_VERSION" == "$CURRENT_VERSION" ]]; then
	log "no update: zabbly $BRANCH is still $NEW_TAG"
	exit 0
fi

log "update available: $CURRENT_VERSION -> $NEW_VERSION ($NEW_TAG), preparing scratch build"

SCRATCH="${CHECKOUT}-auto-$(date -u +%Y%m%d%H%M%S)"
cp -r "$CHECKOUT" "$SCRATCH"
cd "$SCRATCH"

shopt -s nullglob

# Drop any patches tracked from a previous run before fetching this run's set,
# so a shrinking/renumbered zabbly cherry-pick list never leaves stale files
# (and stale Patch: references) behind.
OLDPATCHES=([0-9][0-9][0-9][0-9]-*.patch)
if [[ ${#OLDPATCHES[@]} -gt 0 ]]; then
	osc rm --force "${OLDPATCHES[@]}"
fi

python3 "$SCRIPTS_DIR/fetch_patches.py" --input "$TMPJSON" --outdir "$SCRATCH" --upstream "$UPSTREAM"

NEWPATCHES=(0*.patch)
if [[ ${#NEWPATCHES[@]} -gt 0 ]]; then
	osc add "${NEWPATCHES[@]}"
fi

python3 "$SCRIPTS_DIR/update_spec.py" \
	--spec "$SCRATCH/incus.spec" \
	--extract "$TMPJSON" \
	--manifest "$SCRATCH/manifest.json" \
	--changes "$SCRATCH/incus.changes" \
	--author "$AUTHOR"

rm -f manifest.json

log "downloading release tarball $NEW_VERSION"
curl -sSL -f -o "incus-${NEW_VERSION}.tar.xz" \
	"https://linuxcontainers.org/downloads/incus/incus-${NEW_VERSION}.tar.xz"
curl -sSL -f -o "incus-${NEW_VERSION}.tar.xz.asc" \
	"https://linuxcontainers.org/downloads/incus/incus-${NEW_VERSION}.tar.xz.asc"

osc rm --force "incus-${CURRENT_VERSION}.tar.xz" "incus-${CURRENT_VERSION}.tar.xz.asc" 2>/dev/null || true
osc add "incus-${NEW_VERSION}.tar.xz" "incus-${NEW_VERSION}.tar.xz.asc"

log "running local build validation: osc build $REPO $ARCH incus.spec"
BUILD_LOG="$SCRATCH/build.log"
if ! osc build "$REPO" "$ARCH" incus.spec > "$BUILD_LOG" 2>&1; then
	log "BUILD FAILED -- leaving scratch checkout for inspection: $SCRATCH"
	log "(likely needs a one-time manual spec fix, same as the 6.23->7.2.0 jump did -- see the header comment)"
	tail -n 60 "$BUILD_LOG"
	exit 1
fi

log "build OK -- promoting to live checkout $CHECKOUT"
cd "$CHECKOUT"

OLD_LIVE_PATCHES=([0-9][0-9][0-9][0-9]-*.patch)
if [[ ${#OLD_LIVE_PATCHES[@]} -gt 0 ]]; then
	osc rm --force "${OLD_LIVE_PATCHES[@]}"
fi
osc rm --force "incus-${CURRENT_VERSION}.tar.xz" "incus-${CURRENT_VERSION}.tar.xz.asc" 2>/dev/null || true

cp "$SCRATCH/incus.spec" .
cp "$SCRATCH/incus.changes" .
cp "$SCRATCH/incus-${NEW_VERSION}.tar.xz" .
cp "$SCRATCH/incus-${NEW_VERSION}.tar.xz.asc" .
cp "$SCRATCH"/0*.patch . 2>/dev/null || true

osc add "incus-${NEW_VERSION}.tar.xz" "incus-${NEW_VERSION}.tar.xz.asc"
NEW_LIVE_PATCHES=(0*.patch)
if [[ ${#NEW_LIVE_PATCHES[@]} -gt 0 ]]; then
	osc add "${NEW_LIVE_PATCHES[@]}"
fi

rm -rf "$SCRATCH"

if [[ "$AUTO_COMMIT" == "1" ]]; then
	log "auto-commit enabled -- committing"
	osc commit -m "Update to Incus $NEW_VERSION (zabbly $BRANCH, automated)"
else
	log "staged and build-validated, NOT committed (pass --auto-commit to enable)."
	log "review with: cd $CHECKOUT && osc status && osc diff incus.spec"
	log "then commit yourself: osc commit -m '...'"
fi
