# Third-Party Notices

## Reckless chess engine

SwiftReckless statically links a maintained fork of
[codedeliveryservice/Reckless](https://github.com/codedeliveryservice/Reckless),
which is distributed under the GNU Affero General Public License, version 3.
The exact source used by the current binary is:

- repository: `https://github.com/fianchettochess/Reckless.git`
- tag: `swiftreckless-v0.9.1`
- commit: `de35beac9074137e9776af14859bf6f40562553c`
- upstream base: `codedeliveryservice/Reckless` tag `v0.9.0`

The full AGPL-3.0 text is reproduced in this repository's [LICENSE](LICENSE).
The fork must remain publicly available at the pinned immutable tag whenever a
corresponding SwiftReckless binary is distributed.

## Other build dependencies

- [rust-lang/libc](https://github.com/rust-lang/libc), used by the Rust FFI
  crate, is offered under `MIT OR Apache-2.0`.
- [apple/swift-crypto](https://github.com/apple/swift-crypto), used for SHA-256
  verification on non-Apple source builds, is offered under Apache-2.0.

Those projects retain their own copyright notices and license texts. They are
resolved from their upstream package repositories rather than copied into this
source tree.

## Reckless NNUE network

`RecklessNetworkLoader` downloads `v54-5478683c.nnue` directly from the public
[RecklessNetworks](https://github.com/codedeliveryservice/RecklessNetworks)
release and verifies its pinned complete SHA-256 digest. The network is not
committed to or redistributed by this repository. It is a Reckless project
artifact and is covered here under the same AGPL-3.0 terms as the Reckless
engine: the upstream [v0.9.0 release](https://github.com/codedeliveryservice/Reckless/releases/tag/v0.9.0)
applies AGPL-3.0 to the project in the same release that documents the updated
NNUE architecture, while RecklessNetworks identifies itself as the dedicated
storage repository for those engine models. RecklessNetworks does not currently
duplicate the license file, so this notice records both the project license and
the separately hosted asset provenance explicitly.
