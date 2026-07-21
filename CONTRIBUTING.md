# Contributing to SwiftReckless

Thank you for helping improve SwiftReckless. Keep each pull request focused,
add or update tests for behavior changes, and explain any change to the public
C or Swift API.

## Tests

Run the Swift and Rust suites before submitting a pull request:

```bash
swift test
cargo test --manifest-path rust/Cargo.toml --locked
```

`rust-toolchain.toml` pins stable Rust 1.96.1. Full Apple artifact builds also
pin `nightly-2026-07-21` for tier-3 `-Z build-std` slices; change either pin only
with a reviewed XCFramework rebuild.

The live-engine tests require the gitignored
`rust/networks/v54-5478683c.nnue` file. Without it, the Swift integration tests
record a skip and the Rust smoke test returns without exercising the engine.
Changes to the FFI, engine lifecycle, or binary artifact must be validated with
that network staged.

The source-arm build should also remain healthy:

```bash
SWIFTRECKLESS_FORCE_SOURCE_BUILD=1 swift test
```

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
