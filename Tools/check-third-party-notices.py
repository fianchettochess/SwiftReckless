#!/usr/bin/env python3
"""Check that THIRD_PARTY_NOTICES.md says what this package actually ships.

WHY THIS EXISTS. The notices are what an AGPL corresponding-source or license
reader follows. They listed apple/swift-crypto as a dependency long after it
left Package.swift (Fianchetto-b32.206), and nothing compared the prose with the
files it describes. The sibling SwiftStockfish notices drifted the same way.

WHAT IT CHECKS.
  1. The Reckless fork's repository, tag and commit equal the `reckless` source
     that rust/Cargo.lock actually resolves, and the upstream base tag equals
     .upstream-version.
  2. The repositories linked under `## Other build dependencies` are exactly the
     third-party packages this repository builds with, in both directions: every
     rust/Cargo.lock package other than this crate and the fork, plus every
     `.package(url:)` in Package.swift. Compared by repository name, which is
     the crate name for crates.io packages. A `.package(` call this cannot read
     is a failure, not a skip.

Run from anywhere: python3 Tools/check-third-party-notices.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NOTICES = ROOT / "THIRD_PARTY_NOTICES.md"
MANIFEST = ROOT / "Package.swift"
CARGO_LOCK = ROOT / "rust" / "Cargo.lock"
UPSTREAM = ROOT / ".upstream-version"

THIS_CRATE = "creckless"
FORK_CRATE = "reckless"
DEPENDENCY_SECTION = "## Other build dependencies"

LINK = re.compile(r"\]\((https?://[^)\s]+)\)")
PACKAGE_CALL = re.compile(r"\.package\s*\(")
PACKAGE_URL = re.compile(r"\.package\s*\(\s*(?:name:\s*\"[^\"]*\"\s*,\s*)?url:\s*\"([^\"]+)\"")
LOCK_PACKAGE = re.compile(r"^\[\[package\]\]\s*$", re.MULTILINE)
GIT_SOURCE = re.compile(r"^git\+(?P<repo>[^?#]+)\?tag=(?P<tag>[^#]+)#(?P<commit>[0-9a-f]{40})$")


def repository_name(url: str) -> str:
    name = url.strip().rstrip("/").rsplit("/", 1)[-1].lower()
    return name[:-4] if name.endswith(".git") else name


def strip_swift_comments(source: str) -> str:
    # String literals are matched first and kept, so the `//` inside a URL is
    # not mistaken for a comment. Prose in comments names dependencies that
    # left ("which dropped swift-crypto") and must not count.
    token = re.compile(r'("(?:\\.|[^"\\\n])*")|/\*.*?\*/|//[^\n]*', re.DOTALL)
    return token.sub(lambda match: match.group(1) or "", source)


def section(notices: str, heading: str) -> str | None:
    start = notices.find(heading)
    if start < 0:
        return None
    body = notices[start + len(heading):]
    following = re.search(r"^## ", body, re.MULTILINE)
    return body[: following.start()] if following else body


def cargo_packages() -> dict[str, dict[str, str]]:
    packages: dict[str, dict[str, str]] = {}
    for block in LOCK_PACKAGE.split(CARGO_LOCK.read_text(encoding="utf-8"))[1:]:
        fields = dict(re.findall(r'^(\w+)\s*=\s*"([^"]*)"\s*$', block, re.MULTILINE))
        if "name" in fields:
            packages[fields["name"]] = fields
    return packages


def notice_field(notices: str, field: str) -> str | None:
    match = re.search(rf"^- {field}: `([^`]+)`\s*$", notices, re.MULTILINE)
    return match.group(1) if match else None


def main() -> int:
    problems: list[str] = []
    notices = NOTICES.read_text(encoding="utf-8")
    packages = cargo_packages()

    # 1. The fork, as Cargo.lock resolves it.
    fork = packages.get(FORK_CRATE)
    source = GIT_SOURCE.match(fork.get("source", "")) if fork else None
    if source is None:
        problems.append(f"{CARGO_LOCK.name} has no git-tag source for '{FORK_CRATE}' this can read")
    else:
        for field, expected in (
            ("repository", source["repo"]),
            ("tag", source["tag"]),
            ("commit", source["commit"]),
        ):
            stated = notice_field(notices, field)
            if stated != expected:
                problems.append(
                    f"{NOTICES.name} gives the fork {field} as {stated!r}, "
                    f"but {CARGO_LOCK.name} resolves {expected!r}"
                )

    pinned = UPSTREAM.read_text(encoding="utf-8").strip()
    base = re.search(r"^- upstream base: `[^`]+` tag `([^`]+)`\s*$", notices, re.MULTILINE)
    if base is None:
        problems.append(f"{NOTICES.name} has no '- upstream base: `<repo>` tag `<tag>`' line")
    elif base.group(1) != pinned:
        problems.append(
            f"{NOTICES.name} names upstream base {base.group(1)!r} but {UPSTREAM.name} pins {pinned!r}"
        )

    # 2. Everything else that is built in.
    declared = {name for name in packages if name not in (THIS_CRATE, FORK_CRATE)}
    manifest = strip_swift_comments(MANIFEST.read_text(encoding="utf-8"))
    urls = PACKAGE_URL.findall(manifest)
    calls = len(PACKAGE_CALL.findall(manifest))
    if calls != len(urls):
        problems.append(
            f"{MANIFEST.name} has {calls} .package( call(s) but only {len(urls)} read as "
            ".package(url:); teach this check the new form rather than letting it pass"
        )
    declared |= {repository_name(url) for url in urls}

    body = section(notices, DEPENDENCY_SECTION)
    if body is None:
        problems.append(f"{NOTICES.name} has no '{DEPENDENCY_SECTION}' section")
        listed: set[str] = set()
    else:
        listed = {repository_name(url) for url in LINK.findall(body)}

    for name in sorted(listed - declared):
        problems.append(
            f"{NOTICES.name} lists {name}, which neither {MANIFEST.name} nor {CARGO_LOCK.name} brings in"
        )
    for name in sorted(declared - listed):
        problems.append(f"{name} is built in, but {NOTICES.name} does not list it")

    if problems:
        print("third-party notices: FAIL", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1

    print(
        f"third-party notices: PASS (fork {source['tag'] if source else '?'} on upstream {pinned}; "
        f"other dependencies: {', '.join(sorted(declared)) or 'none'})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
