# Usage Examples

The following examples use only the public Swift API (`RecklessEngine` and
`RecklessNetworkLoader`). All snippets assume `import SwiftReckless`.

!!! warning "Use `cancellationSafeOutput` for sequential reads"
    `output` is a single-consumer `AsyncStream` — breaking out of its loop ends it
    permanently, so a later `for await` gets immediate EOF. Use
    `cancellationSafeOutput` for sequential/restartable reads (as every example
    below does); never consume both surfaces on one engine. `output` is only for
    generic `UCIEngine` consumers that retain one long-lived subscription for the
    engine's whole life.

## Setup: provision the net, create the engine, and handshake

```swift
import SwiftReckless

func makeEngine() async throws -> RecklessEngine {
    let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
    let netDir = support.appendingPathComponent("reckless-nets")

    // 1. Ensure the NNUE net is present. Idempotent — fast no-op if already valid.
    // Note: the progress closure fires once at download completion (terminal
    // byte count), not incrementally. fractionCompleted is 1.0 on success.
    try await RecklessNetworkLoader().ensure(in: netDir) { p in
        if let f = p.fractionCompleted {
            print("Downloading net: \(Int(f * 100))%")
        }
    }

    // 2. Create the engine.
    guard let engine = RecklessEngine(networkDirectory: netDir) else {
        throw NSError(domain: "SwiftReckless", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "engine init failed"])
    }

    // 3. Handshake: uci → uciok → isready → readyok.
    // cancellationSafeOutput survives the `break` below; `output` would not.
    engine.uci()
    for await line in engine.cancellationSafeOutput {
        if line == "uciok"   { engine.isReady() }
        if line == "readyok" { break }
    }
    return engine
}
```

## Best move at fixed depth

```swift
func bestMove(for fen: String, depth: Int, engine: RecklessEngine) async -> String? {
    engine.setPosition(fen: fen)
    engine.go(depth: depth)
    for await line in engine.cancellationSafeOutput {
        if line.hasPrefix("bestmove ") {
            return line.split(separator: " ").dropFirst().first.map(String.init)
        }
    }
    return nil
}

// Usage:
let engine = try await makeEngine()
let move = await bestMove(
    for: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
    depth: 20,
    engine: engine
)
print("Best move:", move ?? "none")
```

## Stream a live evaluation bar

Parse `info` lines to drive a centipawn evaluation bar or depth readout:

```swift
struct Eval {
    var depth = 0
    var scoreCp: Int?
    var mateIn: Int?
    var pv: [String] = []
}

func parseInfo(_ line: String) -> Eval? {
    guard line.hasPrefix("info "), line.contains(" pv ") else { return nil }
    var eval = Eval()
    let tokens = line.split(separator: " ").map(String.init)
    var i = 0
    while i < tokens.count {
        switch tokens[i] {
        case "depth": eval.depth = Int(tokens[i + 1]) ?? 0; i += 2
        case "score":
            if tokens[i + 1] == "cp"   { eval.scoreCp = Int(tokens[i + 2]) }
            if tokens[i + 1] == "mate" { eval.mateIn  = Int(tokens[i + 2]) }
            i += 3
        case "pv":
            eval.pv = Array(tokens[(i + 1)...]); i = tokens.count
        default: i += 1
        }
    }
    return eval
}

engine.setPosition(fen: "startpos", moves: ["e2e4", "e7e5"])
engine.go(depth: 24)
for await line in engine.cancellationSafeOutput {
    if let eval = parseInfo(line) {
        let score = eval.scoreCp.map { "\($0)cp" } ?? "mate \(eval.mateIn ?? 0)"
        print("depth \(eval.depth)  score \(score)  pv \(eval.pv.prefix(5).joined(separator: " "))")
    }
    if line.hasPrefix("bestmove ") { break }
}
```

## Infinite analysis with `stop`

```swift
engine.setPosition(fen: "startpos")
engine.goInfinite()

// Let it run for a few seconds, then stop.
try await Task.sleep(for: .seconds(5))
engine.stop()

// Collect the bestmove after stop.
for await line in engine.cancellationSafeOutput {
    if line.hasPrefix("bestmove ") {
        print("Stopped at:", line)
        break
    }
}
```

## Time-managed search (clock game)

```swift
// White has 2 minutes, Black has 1 minute 55 seconds, 2s increment each.
engine.setPosition(fen: "startpos", moves: ["e2e4", "e7e5", "g1f3"])
engine.go(wtime: 120_000, btime: 115_000, winc: 2_000, binc: 2_000)
for await line in engine.cancellationSafeOutput {
    if line.hasPrefix("bestmove ") {
        print(line)
        break
    }
}
```

## Top-3 candidates (MultiPV)

```swift
engine.send("setoption name MultiPV value 3")
engine.setPosition(fen: "startpos")
engine.go(depth: 18)

var candidates: [Int: String] = [:]   // multipv index → first pv move

for await line in engine.cancellationSafeOutput {
    if line.hasPrefix("info "),
       let idxRange = line.range(of: "multipv ") {
        let idxStr = line[idxRange.upperBound...].prefix { $0.isNumber }
        let idx = Int(idxStr) ?? 0
        if let pvRange = line.range(of: " pv ") {
            candidates[idx] = line[pvRange.upperBound...]
                .split(separator: " ").first.map(String.init)
        }
    }
    if line.hasPrefix("bestmove ") { break }
}

print(candidates)   // e.g. [1: "e2e4", 2: "d2d4", 3: "g1f3"]
```

## Using `setPosition` with a move list

```swift
// Start position + first three moves of the Italian Game.
engine.setPosition(fen: "startpos", moves: ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4"])
engine.go(depth: 22)
```

## New game between searches

```swift
// Reset hash tables between independent positions.
engine.newGame()
engine.setPosition(fen: "startpos")
engine.go(depth: 20)
```

## Tear down

```swift
engine.shutdown() // joins the Rust thread, frees state, and finishes output
// Releasing the reference also triggers deinit-based teardown if omitted.
```

Only one engine may be live at a time. After `shutdown()` returns, a new
`RecklessEngine` may be created in the same process; the pinned fork supports
restartable sequential lifetimes.
