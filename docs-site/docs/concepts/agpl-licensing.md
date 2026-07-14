# AGPL-3.0 Licensing

SwiftReckless is distributed under the **GNU Affero General Public License,
version 3** (AGPL-3.0).

## Why AGPL-3.0

The Reckless chess engine is licensed AGPL-3.0. SwiftReckless links the engine's
compiled code directly into its output — the `RecklessFFI.xcframework` on Apple
platforms, or the source-built `libcreckless` static library on Android and other
platforms. Because static linking incorporates the AGPL-3.0 work into the output,
the whole SwiftReckless package is an AGPL-3.0 artifact, and any binary that
includes SwiftReckless is governed by AGPL-3.0.

## Key AGPL-3.0 obligations

### Source availability (AGPL §1–6, same as GPL-3.0)

Any distribution of a binary that incorporates SwiftReckless must:

- Include or offer the complete Corresponding Source (your application's source
  code and the SwiftReckless + Reckless sources).
- License the distributed binary under AGPL-3.0 (or a compatible license for
  components licensed under compatible terms).

### Network interaction (AGPL §13)

AGPL-3.0 extends the GPL source-offer obligation to **remote network interaction**:
if you run a modified version of the covered work as part of a network-accessible
service (e.g. a chess server that evaluates positions using SwiftReckless), you must
offer that service's users the Corresponding Source of your modified version.

This obligation does not apply to unmodified versions running locally on a user's
own device. A standard chess app distributed on the App Store that ships SwiftReckless
unmodified and runs the engine locally is subject to the standard AGPL-3.0 source
offer, not the network-interaction clause.

## Compatibility with Stockfish (GPL-3.0)

The Reckless engine (AGPL-3.0) is compatible with Stockfish (GPL-3.0) in the sense
that AGPL-3.0 is a stronger copyleft that is GPL-3.0 compatible. A combined binary
that links both engines (if ever shipped) must offer the Corresponding Source for
both engines and must comply with AGPL-3.0 for the combined work.

In Fianchetto, the two engines are never simultaneously linked into the same binary
target — they are separate SPM products (`SwiftReckless` and `SwiftStockfish`) that
a consuming target links individually.

## Reckless engine upstream

| Property | Value |
|---|---|
| Upstream | https://github.com/codedeliveryservice/Reckless |
| License | AGPL-3.0 |
| Fork used | `github.com/fianchettochess/Reckless.git`, pinned `rev = "420b3d7"` |
| Fork branch | `swiftreckless` on upstream tag `v0.9.0` |

The fork makes four focused patches: it adds a `[lib]` target (upstream Reckless is
binary-only), replaces the compile-time NNUE embed with runtime loading, makes UCI
I/O instance-local, and guards terminal positions with no legal root move. These
changes are required by the wrapper's library and multi-instance execution model.

## SwiftReckless license file

The `LICENSE` file at the root of the SwiftReckless repository contains the full
AGPL-3.0 text and is the authoritative license for the package.

## Practical guidance

- **App Store distribution**: AGPL-3.0 does not prohibit App Store distribution,
  but you must make the Corresponding Source available (e.g. via a public GitHub
  repository or a written offer). Apple's standard App Store agreement is compatible
  with distributing AGPL-3.0 software as long as source availability obligations are
  met externally.
- **Modifications**: If you modify SwiftReckless or the Reckless fork and distribute
  the resulting binary, you must publish those modifications under AGPL-3.0.
- **Network services**: If you run a modified version behind a network API, AGPL §13
  requires you to offer source to users of that service.

!!! info "This is not legal advice"
    The above is an engineering-oriented summary of AGPL-3.0 obligations as they
    apply to this package. For legal advice specific to your situation, consult a
    qualified attorney.
