# SwiftReckless Kickoff Assessment (#97) — 2026-07-01

Source-grounded assessment of the SwiftReckless scaffold + the real Reckless crate (tag `v0.9.0`,
`github.com/codedeliveryservice/Reckless`, AGPL-3.0). Supersedes the scaffold's original assumptions.

## Verdict
The scaffold is an **architecturally-coherent skeleton with a hollow, partly-mis-specified core.** The
Swift/C-bridge layers mirror SwiftStockfish well, but the engine is not linked and three core assumptions
are wrong. This is a bigger and *different* job than "uncomment the dep."

## Definitive findings (from the real Reckless source)
1. **Reckless is a BINARY crate, not a library.** `src/main.rs`, no `lib.rs`, no `[lib]`/`crate-type` in its
   `Cargo.toml`. There is **no `reckless::run()` library API** — the scaffold's `ffi.rs` template assumed one.
   The real entry is `pub fn uci::message_loop(VecDeque<String>)` (`src/uci.rs:40`): it drains the passed
   args, then reads `std::io::stdin()` (line 113) interactively, and writes all output via `println!` to
   **stdout (fd 1)** (`readyok`/`uciok`/`bestmove`/`id name`…). `main()` = `lookup::initialize(); nnue::initialize(); uci::message_loop(args)`.
2. **The NNUE net is COMPILE-TIME embedded, not runtime-loaded.** `src/nnue.rs:295`:
   `static PARAMETERS = transmute(*include_bytes!(env!("MODEL")))`. `build/build.rs` downloads
   `v54-5478683c.nnue` (via `curl`) at build time and bakes it in. ⇒ **No runtime net provisioning.**
   `RecklessNetworkLoader.swift` + `init?(networkFile:)` are unnecessary; the Android swift-crypto/SHA gap is moot.
3. **iOS cannot spawn subprocesses**, so the pipe-driven-UCI-*binary* fallback is out on iOS. Reckless must run
   **in-process** — exactly why SwiftStockfish compiles Stockfish in and its bridge swaps `std::cin/cout`.

## Real architecture (revised)
- **Vendor + minimally fork Reckless** into SwiftReckless (AGPL source-availability is satisfied by vendoring):
  add a `lib.rs` that `pub mod`s the existing modules + `pub fn run(buffer: VecDeque<String>) { lookup::initialize(); nnue::initialize(); uci::message_loop(buffer); }`, and a `[lib] crate-type=["rlib"]` to its `Cargo.toml`.
  **No engine-logic change** — purely a library surface over the existing binary's modules. `creckless` depends on
  the vendored copy by `path`.
- **`creckless` FFI (`ffi.rs`) drives it in-process via fd redirection** (mirroring CStockfish's cin/cout swap):
  redirect **fd 0 (stdin) and fd 1 (stdout)** to pipes (`libc::pipe`/`dup2`), spawn a thread running
  `reckless::run(initial_buffer)` (reads the piped stdin, writes the piped stdout), a reader thread on the
  stdout pipe → the C callback, and `rk_ffi_send_command` writes to the stdin pipe. (The existing `mpsc`-channel
  template doesn't fit — `message_loop` reads stdin, not a channel.)
- **`RecklessEngine.swift`**: drop the net loader + network-path init; `init?()` (net is baked in). Keep the
  `output: AsyncStream<String>` / `send` / `uci` / `isReady` / `quit` shape.
- **Mutual exclusion:** both Stockfish and Reckless hijack **process-global stdio** in-process, so only **one
  engine may be live at a time.** The app's engine-selection must tear down one before starting the other.
  (In practice the user picks one engine; enforce teardown-before-switch.)

## `UCIEngine` protocol (unchanged plan, one tweak)
Define `public protocol UCIEngine` in ChessCore (transport: `output`/`send`/`uci`/`isReady`/`quit` + a creation
entry). Conform `StockfishEngine` + `RecklessEngine` in their own packages (no ChessCore→engine inversion).
Tweak: creation differs (Stockfish needs a runtime net dir; Reckless needs nothing) — make the protocol's
creation tolerate both (e.g. `init?(networkDirectory: URL?)`, Reckless ignores it).

## Revised phased plan
- **P1 — Vendor + fork Reckless (lib target) + FFI + host spike (RISKY, do first).** Vendor the source, add
  lib.rs/`[lib]`, implement `rk_ffi_*` with fd 0/1 redirection, and a host spike: `reckless::run(["uci","quit"])`
  → capture `uciok`/`id name Reckless` off the redirected stdout. *Gate:* spike prints the captured lines; then
  `go depth 1` → `bestmove` end-to-end. **If fd-redirect capture fails, the whole in-process model is in question.**
- **P2 — SwiftReckless builds against the real lib.** Fix `Package.swift` (dangling `RecklessFFI.xcframework`),
  drop the net loader, adjust `RecklessEngine.init?`. *Gate:* `swift build` (host) succeeds; a Swift-level smoke test
  gets `uciok`.
- **P3 — Apple xcframework.** `build-xcframework.sh` (darwin/ios/ios-sim); commit the xcframework. *Gate:* clean-checkout `swift build` on Apple, no manual steps.
- **P4 — Android from-source cross-compile (RISKY, on-device).** Needs rustup targets + cargo-ndk + NDK.
  build.rs runs `curl` on the host (net baked in) — fine. Cross-compile `creckless` (+ vendored reckless) for
  `aarch64-linux-android`; wire into Skip like SwiftStockfish. *Gate:* `.a` builds for aarch64-android AND the app links + runs it on device.
- **P5 — `UCIEngine` protocol + conformances** in ChessCore + both packages. *Gate:* all packages `swift build`.
- **P6 — Make Reckless selectable (mechanical).** Add `.reckless` to `FianchettoKit.PlayConfig.Engine`
  (`EngineTypes.swift:11`; the exhaustive `switch` at `EngineManager+Play.swift:65` flags the wiring site) + the
  Android `PlayVsEngineConfig.Opponent`; hold `any UCIEngine` in EngineManager (iOS)/EngineProbe (Android). *Gate:* both apps build; Reckless plays a legal move on device. (Cleaner after backlog E6 so EngineManager already holds `any UCIEngine`.)

## Risks / prerequisites
- **Toolchain:** host `cargo`/`rustc` present (brew `rust`); **`rustup` MISSING** (needed for cross-targets), no
  `cargo-ndk`, no NDK. P1–P2 (host) work now; P3–P4 need the installs.
- **Build-time net download:** `build.rs` shells `curl` for `v54-5478683c.nnue` → build needs network; net is baked
  into the `.a`/xcframework (bigger artifact). `EVALFILE` env or a pre-placed `networks/` file avoids the download.
- **AGPL-3:** vendoring Reckless into SwiftReckless (its own AGPL repo) satisfies source-availability; but linking it
  into Fianchetto makes the **whole app** an AGPL derivative — whole-app source offer on distribution; §13 if ever
  offered over a network. Ship-time legal call.
- **Fork maintenance:** we carry a vendored+patched Reckless (a thin lib.rs over upstream). Re-sync on engine upgrades.
- **Not test-coverable (on-device):** fd-redirect capture; Stockfish+Reckless stdio mutual-exclusion; Android NDK
  cross-compile via Skip; `panic = abort` (engine panic = app crash).
