# SwiftReckless

A Swift Package Manager wrapper around the [Reckless](https://github.com/codedeliveryservice/Reckless)
chess engine — a competitive UCI engine written in Rust (~3000 Elo, Super-GM level).

The engine runs **in-process** via a Rust-to-C FFI bridge; each UCI output line is
delivered to the Swift layer as an element of an `AsyncStream<String>`. The Swift API
mirrors `StockfishEngine` in [SwiftStockfish](https://github.com/fianchettochess/SwiftStockfish)
so the existing `UCIInfoParser` / `EngineProbe` layer in Fianchetto can be adapted to
either engine with minimal changes.

!!! danger "AGPL-3.0"
    SwiftReckless is distributed under the **GNU Affero General Public License, version 3**,
    because it links the Reckless engine's compiled code. See [AGPL-3.0 licensing](concepts/agpl-licensing.md)
    for what that means for your application.

## Components

| Type | Role |
|---|---|
| `RecklessEngine` | A live engine you talk to in UCI — `send(_:)` commands, read the `output` `AsyncStream`. |
| `RecklessNetworkLoader` | Downloads and verifies (SHA-256) the required NNUE network at runtime. |

## Requirements

!!! warning "Provision the NNUE net before creating the engine"
    `RecklessEngine.init(networkDirectory:)` returns `nil` if the NNUE net
    (`v54-5478683c.nnue`) is not present in `networkDirectory`. Always `await`
    `RecklessNetworkLoader().ensure(in:)` first.

!!! warning "One engine per process"
    The Rust engine owns process-global state (lookup tables, NNUE weights). Only one
    `RecklessEngine` may be alive in a process at a time. Sequential lifetimes are
    supported: fully shut down the current engine before creating another one.
    An overlapping `RecklessEngine(networkDirectory:)` returns `nil`.

## Quick start

```swift
import SwiftReckless

// 1. Ensure the NNUE net exists in a writable directory.
let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let dir = support.appendingPathComponent("reckless-nets")
// Progress fires once at completion (not incrementally).
try await RecklessNetworkLoader().ensure(in: dir) { p in
    if let f = p.fractionCompleted { print("net: \(Int(f * 100))%") }
}

// 2. Create the engine.
guard let engine = RecklessEngine(networkDirectory: dir) else {
    fatalError("engine failed to start — net missing or unreadable")
}

// 3. Read UCI output, send commands.
Task {
    for await line in engine.output {
        if line == "uciok"   { engine.isReady() }
        if line == "readyok" { engine.send("go depth 20") }
        if line.hasPrefix("bestmove ") {
            print("best:", line.split(separator: " ").dropFirst().first ?? "?")
            engine.shutdown()
            break
        }
    }
}
engine.uci()
engine.send("position startpos")
```

## See Also

- [Installation](installation.md) — add SwiftReckless via Swift Package Manager.
- [Getting Started](getting-started.md) — the minimal lifecycle: net → engine → UCI.
- **Concepts** — one page per major subsystem, starting with the
  [Engine API](concepts/engine-api.md).
- [Usage Examples](examples.md) — task-oriented code samples.

## Licensing

SwiftReckless is distributed under the **GNU Affero General Public License, version 3**
(AGPL-3.0). Because it links the Reckless engine's compiled code directly into its
output, the whole package is an AGPL-3.0 artifact. See [AGPL-3.0 licensing](concepts/agpl-licensing.md)
for the full implications.
