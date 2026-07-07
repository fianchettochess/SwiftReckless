# Getting Started

Provision the NNUE network, create the engine, and exchange UCI.

## 1. Provision the NNUE network

The NNUE network (`v54-5478683c.nnue`) is **not embedded** in the engine binary —
it is loaded from disk at runtime. The engine returns `nil` on initialization if the
file is missing or unreadable, so always ensure the net is present before creating
the engine.

`RecklessNetworkLoader.ensure(in:)` is idempotent: a valid, present net is never
re-downloaded (it verifies the SHA-256 prefix and returns immediately). Only a
missing or invalid file triggers a download.

```swift
import SwiftReckless

let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let netDir = support.appendingPathComponent("reckless-nets")

try await RecklessNetworkLoader().ensure(in: netDir) { progress in
    if let fraction = progress.fractionCompleted {
        print("Downloading net: \(Int(fraction * 100))%")
    } else {
        print("Downloading net: \(progress.bytesDownloaded) bytes")
    }
}
```

The progress closure is called only when a download is in progress. On a warm
launch where the net is already present and valid, `ensure` returns immediately
without calling the closure.

## 2. Create the engine

`RecklessEngine.init(networkDirectory:)` is failable — it returns `nil` if the
NNUE net is absent from `networkDirectory` or if the Rust FFI layer could not start
the engine thread.

```swift
guard let engine = RecklessEngine(networkDirectory: netDir) else {
    fatalError("engine failed to start — net missing or Rust FFI error")
}
```

!!! warning "One engine per process"
    Only one `RecklessEngine` may be alive in a process at a time. The Rust engine
    owns process-global state (lookup tables, NNUE weights). Always fully tear down
    (`engine.quit()` + release the reference) before creating another instance.

## 3. Read output and send commands

`engine.output` is an `AsyncStream<String>` of UCI lines, delivered in order, with
no trailing newline. Read it from a `Task` while sending commands from any context.

```swift
Task {
    for await line in engine.output {
        print("engine>", line)
        if line == "uciok"   { engine.isReady() }
        if line == "readyok" { break }   // engine is ready; proceed below
    }
}

engine.uci()   // sends "uci"; engine replies with id/option lines then "uciok"
```

## 4. Run a search

Once `readyok` is received, set a position and start a search. The engine emits
`info` lines with search progress, then a final `bestmove` line.

```swift
engine.setPosition(fen: "startpos")
engine.go(depth: 20)

for await line in engine.output {
    if line.hasPrefix("bestmove ") {
        let move = line.split(separator: " ").dropFirst().first.map(String.init)
        print("Best move:", move ?? "none")
        break
    }
}
```

## 5. Tear down

```swift
engine.quit()   // sends "quit"; Rust engine thread joins and all memory is freed
// Release the engine reference — deinit also tears down if quit() was not called.
```

## Full minimal example

```swift
import SwiftReckless

@main struct MinimalReckless {
    static func main() async throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let netDir = support.appendingPathComponent("reckless-nets")

        // 1. Ensure the NNUE net is present.
        try await RecklessNetworkLoader().ensure(in: netDir)

        // 2. Create the engine.
        guard let engine = RecklessEngine(networkDirectory: netDir) else {
            fatalError("engine init failed")
        }

        // 3. Handshake then search.
        engine.uci()
        for await line in engine.output {
            if line == "uciok"   { engine.isReady() }
            if line == "readyok" {
                engine.setPosition(fen: "startpos")
                engine.go(depth: 18)
            }
            if line.hasPrefix("bestmove ") {
                print(line)
                engine.quit()
                break
            }
        }
    }
}
```

## API summary

```swift
public final class RecklessEngine: @unchecked Sendable {
    public init?(networkDirectory: URL)
    public var output: AsyncStream<String> { get }
    public func send(_ command: String)
    public func uci()
    public func isReady()
    public func newGame()
    public func quit()
    public func setPosition(fen: String = "startpos", moves: [String] = [])
    public func goInfinite()
    public func go(depth: Int)
    public func go(wtime: Int, btime: Int, winc: Int = 0, binc: Int = 0)
    public func stop()
}
```

## See also

- [Engine API](concepts/engine-api.md) — full reference for `RecklessEngine`.
- [NNUE Network Loader](concepts/nnue-loader.md) — the loader in depth.
- [Build model](concepts/build-model.md) — Apple xcframework vs. Android source build.
- [Usage Examples](examples.md) — task-oriented code samples.
