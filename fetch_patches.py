#!/usr/bin/env python3
"""Fetch each cherry-picked commit (from extract_zabbly.py's JSON) from the
upstream repo as a numbered patch file, and write a manifest.json describing
what was written.

Prefers `gh api` (authenticated, avoids anonymous rate limits) and falls back
to the public https://github.com/<repo>/commit/<sha>.patch URL if gh isn't
available.
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path


def slugify(subject, maxlen=50):
    s = re.sub(r'[^a-zA-Z0-9]+', '-', subject).strip('-').lower()
    return s[:maxlen].rstrip('-') or "patch"


def fetch_via_gh(owner_repo, sha):
    out = subprocess.run(
        ["gh", "api", f"repos/{owner_repo}/commits/{sha}",
         "-H", "Accept: application/vnd.github.v3.patch"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip())
    return out.stdout


def fetch_via_http(owner_repo, sha):
    url = f"https://github.com/{owner_repo}/commit/{sha}.patch"
    req = urllib.request.Request(url, headers={"User-Agent": "incus-obs-prep-script"})
    with urllib.request.urlopen(req) as resp:
        return resp.read().decode("utf-8")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input", required=True, help="JSON produced by extract_zabbly.py")
    ap.add_argument("--outdir", required=True, help="Directory to write NNNN-slug.patch files into")
    ap.add_argument("--upstream", default="lxc/incus", help="owner/repo of the upstream project")
    ap.add_argument("--start", type=int, default=1, help="Starting patch number")
    ap.add_argument("--sleep", type=float, default=0.3, help="Delay between fetches (seconds)")
    args = ap.parse_args()

    data = json.loads(Path(args.input).read_text())
    picks = data["cherry_picks"]

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    have_gh = shutil.which("gh") is not None

    manifest = []
    width = max(4, len(str(args.start + len(picks) - 1)))
    for i, pick in enumerate(picks, start=args.start):
        sha, subject = pick["sha"], pick["subject"]
        num = str(i).zfill(width)
        fname = f"{num}-{slugify(subject)}.patch"
        fpath = outdir / fname
        try:
            content = fetch_via_gh(args.upstream, sha) if have_gh else fetch_via_http(args.upstream, sha)
        except Exception as e:
            sys.exit(f"error: failed to fetch {sha} ({subject!r}): {e}")
        fpath.write_text(content)
        manifest.append({"number": i, "file": fname, "sha": sha, "subject": subject})
        print(f"[{i}/{len(picks)}] {fname}  ({sha[:12]})", file=sys.stderr)
        time.sleep(args.sleep)

    (outdir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {len(picks)} patches to {outdir}", file=sys.stderr)


if __name__ == "__main__":
    main()
