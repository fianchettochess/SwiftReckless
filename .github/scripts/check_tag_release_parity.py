#!/usr/bin/env python3
"""Every release tag must have a release, and ship the asset it names.

WHY THIS EXISTS
---------------
Releases here are made by `release.yml`, which builds the asset, rewrites the
binaryTarget to url+checksum, and creates the tag THROUGH the release. A tag
made any other way — `git tag && git push` — looks identical in `git tag`
output but has no asset, no checksum, and nothing on the releases page.

Three accumulated that way here — 0.9.12, 0.9.13 and 0.9.14 — and were only
found by listing tags against releases by hand on 2026-09-07. All three were
PATH MODE: their manifests pointed at `Frameworks/RecklessFFI.xcframework`,
so they resolved only because that 148 MB binary happened to be committed in
the tree. They were deleted rather than repaired, because a release tag has
to point at a release commit and force-moving a published tag is not a thing
this repository does. The same sweep found four in SwiftStockfish.

Nothing detected any of it. `git tag` was happy, CI was green, and the drift
was only visible by comparing two lists nobody compares.

WHAT IT CHECKS, per tag matching N.N.N
--------------------------------------
  1. A GitHub Release exists for it.
  2. That release carries at least one asset.
  3. The tag's Package.swift declares a url+checksum binaryTarget — not a
     `path:` one — because a `path:` tag is PATH MODE: it resolves only because
     the binary happens to be in that tree, which is precisely what this
     repository stopped doing.
  4. The URL names this tag, so a manifest cannot point at another release's
     asset.

Exit 1 on any failure, naming every one — a check that stops at the first is a
check you run several times.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys

TAG_RE = re.compile(r"^\d+\.\d+\.\d+$")
URL_RE = re.compile(r'url:\s*"([^"]+)"')
CHECKSUM_RE = re.compile(r'checksum:\s*"([0-9a-f]{64})"')


def binary_target_block(manifest: str) -> str | None:
    """The text INSIDE the `.binaryTarget(...)` call, or None if there is none.

    SCOPED, NOT FIRST-MATCH. Searching the whole manifest for `url:` finds
    whichever comes first, and in this package that is the swift-crypto
    package dependency on line 125 — so every tag was reported as "points at
    another release: https://github.com/apple/swift-crypto.git" while its
    binaryTarget was perfectly correct twenty lines below. A check that fails
    on nine healthy tags gets switched off, which is worse than not having it.
    """
    start = manifest.find(".binaryTarget(")
    if start < 0:
        return None
    i = manifest.index("(", start)
    depth = 0
    for j in range(i, len(manifest)):
        if manifest[j] == "(":
            depth += 1
        elif manifest[j] == ")":
            depth -= 1
            if depth == 0:
                return manifest[i + 1:j]
    return None


def run(*args: str) -> str:
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout


def manifest_at(tag: str) -> str:
    """Package.swift as that tag has it, with comments stripped.

    Comments are stripped because this file DOCUMENTS both modes at length —
    including a literal `url: "https://.../<version>/..."` example — and a
    checker that reads the documentation instead of the declaration passes a
    tag that ships nothing.
    """
    text = run("git", "show", f"{tag}:Package.swift")
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("//"))


def main() -> int:
    tags = [t for t in run("git", "tag").split() if TAG_RE.match(t)]
    if not tags:
        print("tag/release parity: FAIL — no version tags found; is this a full clone?")
        return 1

    # The REST API, not `gh release list --json`: that command's field set does
    # not include `assets`, so it cannot answer whether a release actually
    # shipped anything — which is half of what this check is for.
    released = {
        r["tag_name"]: r
        for r in json.loads(run("gh", "api", "--paginate", "repos/{owner}/{repo}/releases"))
    }

    problems: list[str] = []
    for tag in sorted(tags, key=lambda t: [int(p) for p in t.split(".")]):
        release = released.get(tag)
        if release is None:
            problems.append(f"{tag}: tagged but never released — made outside release.yml")
            continue
        if not release.get("assets"):
            problems.append(f"{tag}: release exists but carries no asset")

        manifest = binary_target_block(manifest_at(tag))
        if manifest is None:
            problems.append(f"{tag}: manifest declares no binaryTarget at all")
            continue
        url = URL_RE.search(manifest)
        if url is None:
            problems.append(
                f"{tag}: manifest has no url: binaryTarget (PATH MODE — resolves only "
                f"if the binary is committed in that tree)"
            )
        elif f"/download/{tag}/" not in url.group(1):
            problems.append(f"{tag}: manifest points at another release: {url.group(1)}")
        if CHECKSUM_RE.search(manifest) is None:
            problems.append(f"{tag}: manifest has no checksum for its binaryTarget")

    if problems:
        print(f"tag/release parity: FAIL — {len(problems)} problem(s)")
        for p in problems:
            print(f"  {p}")
        print("\nA tag made by hand cannot be repaired into a release: the release commit "
              "is built by the release workflow and the tag must point at it. Cut a new "
              "version with the workflow, then delete the hand-made tag.")
        return 1

    print(f"tag/release parity: PASS ({len(tags)} tags, all released with url+checksum assets)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
