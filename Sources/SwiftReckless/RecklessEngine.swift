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
//  NNUE NOTE: Reckless requires the network file `v60-7f587dfb.nnue` to exist
//  at the path passed to `init(networkFile:)`.  Use `RecklessNetworkLoader` to
//  download it before creating an engine instance.  Reckless panics (and takes
//  down the process) if the net is absent — just like Stockfish.
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
///   exists at `networkFile` BEFORE creating the engine.  Reckless loads its
///   evaluation net during initialisation and panics if it is missing or
///   invalid, which would terminate the entire host process.  Run
///   ``RecklessNetworkLoader/ensure(in:progress:)`` first.
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
    /// - Parameter networkFile: URL of the NNUE network file
    ///   (`v60-7f587dfb.nnue`) that Reckless should load.  The file must exist
    ///   before this call — use ``RecklessNetworkLoader`` to provision it.
    ///
    /// - Returns: `nil` if the Rust FFI layer could not start the engine.
    public init?(networkFile: URL) {
        var continuation: AsyncStream<String>.Continuation!
        self._output = AsyncStream(bufferingPolicy: .unbounded) { cont in
            continuation = cont
        }
        self.continuation = continuation

        guard let ref = networkFile.path.withCString({ rk_create($0) }) else {
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
