The upstream watcher found a newer **@NAME@** release.

|  | version |
|---|---|
| Pinned here (`.upstream-version`) | `@PINNED@` |
| Latest upstream release | [`@LATEST@`](https://github.com/@REPO@/releases/tag/@LATEST@) |

> ⚠️ SwiftReckless does **not** vendor the engine — it builds from the patched fork [`fianchettochess/Reckless`](https://github.com/fianchettochess/Reckless) (branch `swiftreckless`), currently based on upstream `@PINNED@` plus four patches: a `[lib]` target, runtime NNUE loading, per-instance I/O, and terminal-position guarding. Moving to `@LATEST@` means **rebasing those patches** onto the new tag — not a mechanical swap.

### Update checklist
- [ ] Rebase the `swiftreckless` branch's four patches onto upstream `@LATEST@` in `fianchettochess/Reckless`
- [ ] Resolve conflicts; confirm the `[lib]` target, runtime NNUE loader, per-instance I/O, and terminal-position guard still apply
- [ ] Update the pinned `rev` in `rust/Cargo.toml` (and the dependency note in `README.md`)
- [ ] Check whether the bundled NNUE net (`v54-…`) changed upstream
- [ ] Rebuild: `Tools/build-xcframework.sh`
- [ ] `swift test`
- [ ] Bump `.upstream-version` to `@LATEST@`
- [ ] Push an `N.N.N` release tag — CI builds the xcframework, checksums it, and publishes

<sub>Opened automatically by `.github/workflows/upstream-watch.yml`; it will not be re-created for `@LATEST@`.</sub>
