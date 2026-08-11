# Contributing to SwiftReckless

Thank you for helping improve SwiftReckless. Keep each pull request focused,
add or update tests for behavior changes, and explain any change to the public
C or Swift API.

## Tests

Run the Swift and Rust suites before submitting a pull request:

```bash
swift test
SWIFTRECKLESS_FORCE_SOURCE_BUILD=1 swift test --scratch-path .build-source
cargo test --manifest-path rust/Cargo.toml --locked --all-targets
```

`rust-toolchain.toml` pins stable Rust 1.96.1. Full Apple artifact builds also
pin `nightly-2026-07-21` for tier-3 `-Z build-std` slices; change either pin only
with a reviewed XCFramework rebuild.

The live-engine tests require the gitignored
`rust/networks/v54-5478683c.nnue` file. Without it, the Swift integration tests
record a skip and the Rust smoke test returns without exercising the engine.
Changes to the FFI, engine lifecycle, or binary artifact must be validated with
that network staged.

That skip is a convenience for you, not a mode CI is allowed to run in. Any job
that stages the net sets `SWIFTRECKLESS_REQUIRE_NET=1`, which turns a missing
net into a failure rather than a skip — otherwise `rust/tests/ffi_smoke.rs`
reports `ok. 1 passed` without touching the FFI, which is precisely what
ci.yml's `rust` job did until the net was staged there. Set it locally too when
you mean to test the engine:

```bash
SWIFTRECKLESS_REQUIRE_NET=1 cargo test --manifest-path rust/Cargo.toml --locked
```

A real run takes a moment and logs `[creckless] rk_ffi_create: ...`; a skip
finishes in `0.00s` and logs nothing. Read that, not the `ok`.

The forced-source test intentionally records a skip for the live-engine suite
on macOS and Linux because those configurations link host stubs. With the
network staged, validate the real Rust engine and terminal-position regression:

```bash
cargo test --manifest-path rust/Cargo.toml --locked --all-targets
cargo run --manifest-path rust/Cargo.toml --locked --example terminal_guard
```

Release CI additionally runs the complete Swift suite on the freshly rebuilt
Apple binary arm, where the live-engine test must execute, and builds/runs the
SemVer-tagged fixture under `Tests/RemoteConsumer`.

## Generated artifacts and privacy

Do not commit NNUE networks, build directories, release archives, credentials,
session URLs, IP addresses, hostnames, or machine-specific checkout/home/temp
paths. The committed XCFramework is a generated release artifact; rebuild it
with the scripts in `Tools/` rather than editing its contents by hand. Before
committing a rebuilt artifact, inspect its printable strings for private paths
and verify its slices and exported `rk_ffi_*` symbols. Generic provenance paths
embedded in Rust's precompiled standard-library objects may remain; they must
not identify this checkout or its builder and should be recorded as an explicit
artifact-policy exception.

Sanitizing a later commit does not remove sensitive content from Git history.
If a credential is committed, stop using it and rotate it rather than relying
on a follow-up deletion.

## Source and license provenance

Contributions must be original or distributed under terms compatible with
AGPL-3.0. Record the URL, immutable revision, and license for any source that
materially informs an implementation. Changes to the maintained Reckless fork
must be available at the immutable tag pinned by `rust/Cargo.toml` before a
SwiftReckless binary is released. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for current provenance.
