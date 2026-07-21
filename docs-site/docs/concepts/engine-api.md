# Engine API

`RecklessEngine` is the public Swift interface to the Reckless UCI engine. It wraps
the C FFI bridge in `CReckless`, exposes a cancellation-safe UCI output channel
(`cancellationSafeOutput`, plus an `AsyncStream<String>` compatibility adapter), and
provides convenience methods for common UCI commands.

Its shape mirrors `StockfishEngine` in SwiftStockfish by design, so the Fianchetto
`UCIInfoParser` / `EngineProbe` layer can be adapted to either engine with minimal
changes.

## Declaration

```swift
public final class RecklessEngine: @unchecked Sendable
```

`@unchecked Sendable` is backed by a Swift teardown lock (which orders sends
against destroy) plus the Rust mutex/channel implementation.

## Lifecycle constraints

!!! danger "One live engine per process"
    The Rust engine owns process-global state: lookup tables and the loaded NNUE
    weights. SwiftReckless rejects an overlapping engine with a `nil` initializer.
    Sequential lifetimes are supported after the current engine completes a
    clean `shutdown()`; see the lifecycle note below.

!!! warning "NNUE net must be present before init"
    `init(networkDirectory:)` returns `nil` if `v54-5478683c.nnue` is not present in
    `networkDirectory`. Call `RecklessNetworkLoader().ensure(in:)` first.

## Initializer

```swift
public init?(networkDirectory: URL)
```

- Creates and starts a Reckless engine instance. Under the hood:
    1. Verifies `networkDirectory/v54-5478683c.nnue` exists on disk.
    2. Calls `rk_create(network_path)`, which loads the NNUE net and spawns a
       background thread running the Reckless UCI loop.
    3. Registers the C output callback that feeds `output`.
- Returns `nil` if the net is absent or if the Rust FFI layer could not start.

## Properties

### `cancellationSafeOutput`

```swift
public var cancellationSafeOutput: RecklessOutput { get }
```

Cancellation-safe, process-lifetime UCI output. Lines are delivered in order,
stripped of their trailing newline. Cancelling or breaking one iterator leaves the
channel reusable for later reads. **Prefer this surface for any consumer that stops
and restarts reads** (e.g. handshake loop, then a separate `bestmove` loop). The
channel finishes when the engine is destroyed (`deinit` or explicit `shutdown()`)
or when the engine thread exits.

### `output`

```swift
public var output: AsyncStream<String> { get }
```

Compatibility shim for the shared `UCIEngine` protocol; **single-consumer and
non-restartable** — breaking out of its `for await` loop ends it permanently. The
stream is unbounded-buffered — iterate promptly if you care about back-pressure. It
finishes when the engine is destroyed (`deinit` or explicit `shutdown()`).

!!! warning "Mutually exclusive with `cancellationSafeOutput`"
    Consuming (or even first-accessing) both surfaces splits UCI lines between two
    consumers — an awaited `bestmove` can be silently diverted and lost. Pick one
    surface per engine.

## Raw command interface

### `send(_:)`

```swift
public func send(_ command: String)
```

Send a raw UCI command string (no trailing newline needed). Thread-safe; can be
called from any Swift concurrency context.

## Convenience UCI commands

### `uci()`

```swift
public func uci()
```

Send `uci`. The engine replies with its `id name`, `id author`, zero or more
`option` lines, then `uciok`.

### `isReady()`

```swift
public func isReady()
```

Send `isready`. The engine replies `readyok` once all pending work (including any
previous `ucinewgame` or `position` processing) is complete.

### `newGame()`

```swift
public func newGame()
```

Send `ucinewgame` to reset hash tables and engine state for a new game.

### `quit()`

```swift
public func quit()
```

Send `quit`, asking the UCI loop to exit. This method sends the UCI command only;
the wrapper still owns the thread handle and engine state. Use `shutdown()` for
synchronous, idempotent joining and destruction.

### `shutdown()`

```swift
public func shutdown()
```

Send the bridge teardown, join the Rust thread, free its state, and finish
`output`. Calls after the first are no-ops; a concurrent `send(_:)` is ordered
safely before or after teardown.

## Position and search helpers

### `setPosition(fen:moves:)`

```swift
public func setPosition(fen: String = "startpos", moves: [String] = [])
```

Compose and send a `position` command. Pass `"startpos"` (the default) for the
starting position, or a full FEN string for any other position. `moves` is an
optional list of long-algebraic moves (`"e2e4"`, `"e7e5"`, …) applied on top of
the position.

Examples:

```swift
engine.setPosition()                               // position startpos
engine.setPosition(fen: "startpos",
                   moves: ["e2e4", "e7e5"])        // position startpos moves e2e4 e7e5
engine.setPosition(fen: "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2")
```

### `goInfinite()`

```swift
public func goInfinite()
```

Start an infinite search (`go infinite`). Send `stop()` to halt it; the engine
then emits a `bestmove` line.

### `go(depth:)`

```swift
public func go(depth: Int)
```

Start a depth-limited search (`go depth <n>`). The engine emits `info` lines as it
searches and a final `bestmove` line.

### `go(wtime:btime:winc:binc:)`

```swift
public func go(wtime: Int, btime: Int, winc: Int = 0, binc: Int = 0)
```

Start a time-managed search. All times are in milliseconds.

### `stop()`

```swift
public func stop()
```

Send `stop` to halt an in-progress infinite or depth search. The engine immediately
emits a `bestmove` line.

## Teardown sequence

The Rust FFI crate guarantees:

1. `rk_destroy` (called by `shutdown()` and `deinit`) sends `"quit"`, drops the command channel,
   and `join()`s the engine thread.
2. After `rk_destroy` returns, no further output callbacks can fire.
3. All memory allocated by the Rust engine (NNUE weights, hash tables) is freed.

There is no use-after-free window. Pinned fork tag `swiftreckless-v0.9.1`
(commit `de35beac9074137e9776af14859bf6f40562553c`) guards global table
initialization, joins the worker pool, and supports unloading the NNUE network.
The FFI therefore rejects overlap but releases its lifecycle slot after a clean
destroy so another sequential engine lifetime can start.

## See also

- [NNUE Network Loader](nnue-loader.md) — provisioning the net before `init`.
- [C FFI bridge](c-ffi-bridge.md) — how `RecklessEngine` maps to the four `rk_*` symbols.
- [Usage Examples](../examples.md)
