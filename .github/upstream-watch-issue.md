The upstream watcher found a newer **@NAME@** release.

|  | version |
|---|---|
| Pinned here (`.upstream-version`) | `@PINNED@` |
| Latest upstream release | [`@LATEST@`](https://github.com/@REPO@/releases/tag/@LATEST@) |

> ⚠️ SwiftReckless does **not** vendor the engine — it builds from the patched fork [`fianchettochess/Reckless`](https://github.com/fianchettochess/Reckless) (branch `swiftreckless`), currently based on upstream `@PINNED@` plus five patches: a `[lib]` target, runtime NNUE loading, per-instance I/O, terminal-position guarding, and restart-safe lifecycle cleanup. Moving to `@LATEST@` means **rebasing those patches** onto the new tag — not a mechanical swap.

### Update checklist
- [ ] Rebase the `swiftreckless` branch's five patches onto upstream `@LATEST@` in `fianchettochess/Reckless`
- [ ] Resolve conflicts; confirm the `[lib]` target, runtime NNUE loader, per-instance I/O, terminal-position guard, and restart-safe lifecycle cleanup still apply
- [ ] Create an immutable fork tag and update the pinned `tag` in `rust/Cargo.toml` (plus the dependency notes in the README and docs)
- [ ] Regenerate `rust/Cargo.lock` and verify `cargo test --locked --manifest-path rust/Cargo.toml`
- [ ] Check whether the bundled NNUE net (`v54-…`) changed upstream
- [ ] Rebuild: `Tools/build-xcframework.sh`
- [ ] `swift test`
- [ ] Bump `.upstream-version` to `@LATEST@`
- [ ] Commit the update, then run **Actions → Release binary** with a new `N.N.N` version (the workflow builds/tests the exact artifact and creates the tag once)

<sub>Opened automatically by `.github/workflows/upstream-watch.yml`; it will not be re-created for `@LATEST@`.</sub>
