#!/usr/bin/env python3
"""Extract INCUS_TAG and the ordered incus cherry-pick list from a zabbly/incus
branch's .github/workflows/builds.yml.

Scoped to the "Build Incus" step (the block starting at `cd /build/incus` and
ending at the next `- name:` step) so cherry-picks for other components can
never leak in, even if zabbly adds inline cherry-picks elsewhere in the future.
"""
import argparse
import json
import re
import subprocess
import sys
import urllib.request

RAW_URL = "https://raw.githubusercontent.com/zabbly/incus/{branch}/.github/workflows/builds.yml"

TAG_RE = re.compile(r'^\s*INCUS_TAG:\s*"?([^"\s]+)"?\s*$')
CHERRY_RE = re.compile(r'^\s*git cherry-pick\s+([0-9a-fA-F]{7,40})\s*(?:#\s*(.*))?$')
STEP_RE = re.compile(r'^\s*-\s*name:')
CD_INCUS_RE = re.compile(r'^\s*cd\s+/build/incus\s*$')


def get_builds_yml(branch, repo):
    if repo:
        out = subprocess.run(
            ["git", "-C", repo, "show", f"{branch}:.github/workflows/builds.yml"],
            capture_output=True, text=True, check=True,
        )
        return out.stdout
    with urllib.request.urlopen(RAW_URL.format(branch=branch)) as resp:
        return resp.read().decode("utf-8")


def extract(text):
    tag = None
    cherry_picks = []
    in_incus_step = False
    for line in text.splitlines():
        m = TAG_RE.match(line)
        if m and tag is None:
            tag = m.group(1)
            continue
        if CD_INCUS_RE.match(line):
            in_incus_step = True
            continue
        if STEP_RE.match(line):
            in_incus_step = False
            continue
        if in_incus_step:
            m = CHERRY_RE.match(line)
            if m:
                sha, subject = m.group(1), (m.group(2) or "").strip()
                cherry_picks.append({"sha": sha, "subject": subject})
    return tag, cherry_picks


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--branch", required=True, choices=["stable", "daily", "lts-6.0", "lts-7.0"])
    ap.add_argument("--repo", help="Path to a local zabbly/incus clone (avoids a network fetch)")
    ap.add_argument("-o", "--output", help="Write JSON here instead of stdout")
    args = ap.parse_args()

    text = get_builds_yml(args.branch, args.repo)
    tag, cherry_picks = extract(text)

    if tag is None:
        sys.exit(f"error: could not find INCUS_TAG in {args.branch}/builds.yml")

    result = {"branch": args.branch, "tag": tag, "cherry_picks": cherry_picks}
    data = json.dumps(result, indent=2)
    if args.output:
        with open(args.output, "w") as f:
            f.write(data + "\n")
    else:
        print(data)

    print(f"# {args.branch}: INCUS_TAG={tag}, {len(cherry_picks)} cherry-picks", file=sys.stderr)


if __name__ == "__main__":
    main()
