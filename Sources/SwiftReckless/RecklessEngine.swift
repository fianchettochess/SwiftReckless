//
//  RecklessEngine.swift
//  SwiftReckless
//
//  A Swift wrapper over the C bridge in CReckless.  The bridge drives
//  Reckless's UCI loop on a background thread (inside the Rust FFI crate)
//  and delivers each output line via a C callback; this class turns that into
//  an `AsyncStream<String>` and exposes a `send(_:)` for UCI commands.
//
//  PUBLIC SHAPE mirrors `StockfishEngine` in SwiftStockfish so that the app's
//  existing UCIInfoParser / EngineProbe layer can be adapted to either engine
//  with minimal changes.
//
//  NNUE NOTE: Reckless requires the network file `v54-5478683c.nnue` to exist
//  in `networkDirectory` before calling `init(networkDirectory:)`.  Use
//  `RecklessNetworkLoader.ensure(in:)` to provision the net first.  The Rust
//  FFI reads the net at runtime (`rk_ffi_create` receives the full path) and
//  returns nil if the file is missing or unreadable.
//
//  CONCURRENCY: one `RecklessEngine` per process — the Rust engine owns
//  process-global tables.  Create, use, destroy one engine before making
//  another.  `@unchecked Sendable` because the opaque `RKEngineRef` is treated
//  as immutable after init and all mutations go through the Rust mutex inside
//  the FFI crate.
//

import Foundation
import CReckless

/// A live Reckless engine instance.
///
/// Talk to it in UCI: send commands with ``send(_:)`` and read replies from
/// the ``output`` async stream.  Convenience methods ``uci()``,
/// ``isReady()``, ``newGame()``, and ``quit()`` cover the most common tokens.
///
/// - Important: The caller MUST ensure the required NNUE network already
///   exists in `networkDirectory` BEFORE creating the engine (the file
///   `v54-5478683c.nnue` must be present there).  The Rust FFI returns `nil`
///   if the file cannot be read, which surfaces as `init` returning `nil`
///   here.  Run ``RecklessNetworkLoader/ensure(in:progress:)`` first.
///
/// - Important: Only ONE `RecklessEngine` may be alive in a process at a time.
///   The Rust engine owns process-global state (lookup tables, NNUE weights).
public final class RecklessEngine: @unchecked Sendable {

    // Opaque Rust handle (`const void *` in C, OpaquePointer in Swift).
    private let engine: RKEngineRef

    // The output stream and its continuation.  The continuation is fed from the
    // C callback, which fires on the Rust engine thread.  `AsyncStream.Continuation`
    // is itself Sendable / thread-safe so no additional locking is needed here.
    private let _output: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    /// An async stream of UCI output lines from the engine, in order.
    ///
    /// Lines are delivered without their trailing newline.  The stream is
    /// unbounded-buffered; iterate it promptly if you care about back-pressure.
    /// It finishes when the engine is destroyed (`deinit` / ``quit()`` →
    /// teardown).
    public var output: AsyncStream<String> { _output }

    /// Create and start a Reckless engine instance.
    ///
    /// - Parameter networkDirectory: A directory that already contains
    ///   `v54-5478683c.nnue` (the required NNUE net).  Use
    ///   ``RecklessNetworkLoader/ensure(in:progress:)`` to provision it.
    ///
    /// - Returns: `nil` if the net file is not present in `networkDirectory`,
    ///   or if the Rust FFI layer could not start the engine.
    public init?(networkDirectory: URL) {
        var continuation: AsyncStream<String>.Continuation!
        self._output = AsyncStream(bufferingPolicy: .unbounded) { cont in
            continuation = cont
        }
        self.continuation = continuation

        // Build the full path to the net file and verify it exists before
        // handing it to the Rust FFI (which returns NULL on failure, but
        // an explicit pre-check gives a clearer early-out).
        let netFile = networkDirectory.appendingPathComponent(
            RecklessNetworkLoader.network.filename
        )
        guard FileManager.default.fileExists(atPath: netFile.path) else {
            fputs("[RecklessEngine] net file not found: \(netFile.path)\n", stderr)
            continuation.finish()
            return nil
        }

        guard let ref = netFile.path.withCString({ rk_create($0) }) else {
            continuation.finish()
            return nil
        }
        self.engine = ref

        // Bridge `self` into the C callback's `void *context` via an unretained
        // pointer.  `self` outlives the bridge: `deinit` destroys the Rust
        // engine (joining its thread) before `self` is deallocated, so the
        // callback can never fire against a freed object.
        let context = Unmanaged.passUnretained(self).toOpaque()
        rk_set_output_callback(engine, { linePtr, ctx in
            guard let linePtr, let ctx else { return }
            let line = String(cString: linePtr)
            let me = Unmanaged<RecklessEngine>.fromOpaque(ctx).takeUnretainedValue()
            me.continuation.yield(line)
        }, context)
    }

    deinit {
        // rk_destroy sends "quit", joins the Rust engine thread, and frees all
        // memory.  After it returns no further callbacks can fire.
        rk_destroy(engine)
        continuation.finish()
    }

    // MARK: - Raw UCI

    /// Send a raw UCI command string (no trailing newline needed).
    public func send(_ command: String) {
        command.withCString { rk_send_command(engine, $0) }
    }

    // MARK: - Convenience UCI commands

    /// Send `uci`.  The engine replies with its `id`/`option` lines then `uciok`.
    public func uci() { send("uci") }

    /// Send `isready`.  The engine replies `readyok` once all pending work is done.
    public func isReady() { send("isready") }

    /// Send `ucinewgame` to reset hash tables and engine state for a new game.
    public func newGame() { send("ucinewgame") }

    /// Send `quit`, asking the UCI loop to exit.
    /// Teardown also happens in `deinit`; call this if you want explicit early
    /// wind-down before the object is released.
    public func quit() { send("quit") }

    // MARK: - Position + Search helpers

    /// Set the current position.
    ///
    /// - Parameters:
    ///   - fen: FEN string, or `"startpos"` for the starting position.
    ///   - moves: Optional list of moves in long-algebraic notation
    ///     (`"e2e4"`, `"e7e5"`, …).
    public func setPosition(fen: String = "startpos", moves: [String] = []) {
        var cmd = "position \(fen == "startpos" ? "startpos" : "fen \(fen)")"
        if !moves.isEmpty {
            cmd += " moves " + moves.joined(separator: " ")
        }
        send(cmd)
    }

    /// Start an infinite search.  Send `stop()` to halt it.
    public func goInfinite() { send("go infinite") }

    /// Start a depth-limited search.
    public func go(depth: Int) { send("go depth \(depth)") }

    /// Start a time-managed search.
    ///
    /// - Parameters:
    ///   - wtime: White time remaining in ms.
    ///   - btime: Black time remaining in ms.
    ///   - winc:  White increment per move in ms.
    ///   - binc:  Black increment per move in ms.
    public func go(wtime: Int, btime: Int, winc: Int = 0, binc: Int = 0) {
        send("go wtime \(wtime) btime \(btime) winc \(winc) binc \(binc)")
    }

    /// Send `stop` to halt an in-progress search.
    public func stop() { send("stop") }
}
