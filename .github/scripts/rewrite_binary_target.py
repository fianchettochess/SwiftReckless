#!/usr/bin/env python3
"""Rewrite Package.swift's ACTIVE binaryTarget to `url:`+`checksum:`.

Used by .github/workflows/release.yml at release time. The committed Package.swift
keeps a PATH-based binaryTarget (`Frameworks/RecklessFFI.xcframework`, built
on-demand) so a plain local `swift build` works once the framework is built; this
script flips it to a URL+checksum binaryTarget inside the CI run, once the release
asset's URL and checksum are known.

The rewrite is IDEMPOTENT across forms: it accepts an active binaryTarget that is
currently `path:`-based OR already `url:`+`checksum:`-based, and always emits the
url+checksum form.

Robustness: Package.swift may contain BOTH a commented-out example binaryTarget
(every line prefixed with `//`) and the real, active
`.binaryTarget(... name: "RecklessFFI" ...)`. We must only touch the active one:
  1. scan for `.binaryTarget(` openers whose line is NOT a `//` comment,
  2. brace-match to the closing `)` of that call,
  3. require the block to contain a non-comment line with `name: "RecklessFFI"`,
and replace exactly that block, preserving its indentation AND whatever trailed
the closing `)` (e.g. the `,` separating it from the next array element). Note the
active binaryTarget lives inside the Apple `if useBinaryEngine { ... }` arm of the
dual-arm manifest; this text transform is agnostic to that.

Usage: rewrite_binary_target.py <url> <checksum> [path-to-Package.swift]
Exits non-zero if it does not find exactly one active binaryTarget, or if the url
contains a character that would break out of the Swift string literal.
"""
import re
import sys

ENGINE_NAME = "RecklessFFI"


def is_comment(line: str) -> bool:
    return line.lstrip().startswith("//")


def find_active_binary_target(lines):
    """Return (start_idx, end_idx_exclusive, indent) of the single active
    `.binaryTarget(...)` block naming RecklessFFI, or raise if not exactly one."""
    matches = []
    for i, line in enumerate(lines):
        if is_comment(line):
            continue
        if ".binaryTarget(" not in line:
            continue
        depth = 0
        end = None
        started = False
        for j in range(i, len(lines)):
            cur = lines[j]
            if is_comment(cur):
                continue
            depth += cur.count("(") - cur.count(")")
            if cur.count("(") > 0:
                started = True
            if started and depth <= 0:
                end = j + 1
                break
        if end is None:
            continue
        block = lines[i:end]
        names_engine = any(
            (not is_comment(b)) and f'name: "{ENGINE_NAME}"' in b for b in block
        )
        if names_engine:
            indent = re.match(r"\s*", line).group(0)
            matches.append((i, end, indent))

    if len(matches) != 1:
        raise SystemExit(
            f"expected exactly 1 active binaryTarget naming {ENGINE_NAME}, "
            f"found {len(matches)}"
        )
    return matches[0]


def closing_suffix(last_block_line: str) -> str:
    """Everything after the final `)` on the block's last line (the array-element
    comma + newline), so the rewritten element stays comma-separated."""
    paren = last_block_line.rfind(")")
    if paren == -1:
        return "\n" if last_block_line.endswith("\n") else ""
    return last_block_line[paren + 1:]


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: rewrite_binary_target.py <url> <checksum> [Package.swift]")
    url = sys.argv[1]
    checksum = sys.argv[2]
    path = sys.argv[3] if len(sys.argv) > 3 else "Package.swift"

    for label, value in (("url", url), ("checksum", checksum)):
        if '"' in value or "\\" in value or "\n" in value or "\r" in value:
            raise SystemExit(
                f'refusing to rewrite: {label} contains a quote, backslash or '
                f'newline that would break the Swift string literal: {value!r}'
            )

    with open(path, "r") as f:
        text = f.read()
    lines = text.splitlines(keepends=True)

    start, end, indent = find_active_binary_target(lines)
    suffix = closing_suffix(lines[end - 1])

    replacement = (
        f"{indent}.binaryTarget(\n"
        f'{indent}    name: "{ENGINE_NAME}",\n'
        f'{indent}    url: "{url}",\n'
        f'{indent}    checksum: "{checksum}"\n'
        f"{indent}){suffix}"
    )

    new_lines = lines[:start] + [replacement] + lines[end:]
    with open(path, "w") as f:
        f.write("".join(new_lines))

    print(f"Rewrote active binaryTarget in {path}:")
    print(f"  url      = {url}")
    print(f"  checksum = {checksum}")


if __name__ == "__main__":
    main()
