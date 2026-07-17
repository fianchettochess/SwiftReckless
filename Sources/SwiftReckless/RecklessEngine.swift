//
//  RecklessEngine.swift
//  SwiftReckless
//
//  A Swift wrapper over the C bridge in CReckless.  The bridge drives
//  Reckless's UCI loop on a background thread (inside the Rust FFI crate)
//  and delivers each output line via a C callback; this class turns that into
//  cancellation-safe ordered async output and exposes `send(_:)` for UCI
//  commands.
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
//  process-global tables. The FFI rejects overlap and, while the pinned fork's
//  lookup initializer remains non-idempotent, rejects a second engine lifetime
//  in the same process. `@unchecked Sendable` is backed by the teardown lock
//  below and the Rust mutex/channel implementation.
//

import Foundation
import CReckless

/// Lock-protected, cancellation-safe FIFO backing ``RecklessOutput``.
///
/// `AsyncStream` cancellation terminates the stream's shared storage. That is
/// unsafe for a process-lifetime engine: cancelling one search iterator would
/// permanently close output for every later search. This storage treats task
/// cancellation as cancellation of only the currently suspended waiter while
/// retaining both the channel and any already-buffered lines.
final class RecklessOutputStorage: @unchecked Sendable {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<String?, Never>
    }

    private let lock = NSLock()
    private var buffered: [String] = []
    private var bufferedStart = 0
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0
    private var isFinished = false

    func next() async -> String? {
        let id: UInt64 = lock.withLock {
            nextWaiterID &+= 1
            return nextWaiterID
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                if bufferedStart < buffered.count {
                    let line = buffered[bufferedStart]
                    bufferedStart += 1
                    compactBufferIfNeededLocked()
                    lock.unlock()
                    continuation.resume(returning: line)
                    return
                }
                if isFinished {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            cancelWaiter(id)
        }
    }

    func yield(_ line: String) {
        let waiter: Waiter?
        lock.lock()
        if isFinished {
            waiter = nil
        } else if waiters.isEmpty {
            buffered.append(line)
            waiter = nil
        } else {
            waiter = waiters.removeFirst()
        }
        lock.unlock()
        waiter?.continuation.resume(returning: line)
    }

    func finish() {
        let pending: [Waiter]
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        pending = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()
        for waiter in pending {
            waiter.continuation.resume(returning: nil)
        }
    }

    var waitingConsumerCount: Int {
        lock.withLock { waiters.count }
    }

    private func cancelWaiter(_ id: UInt64) {
        let waiter: Waiter?
        lock.lock()
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiter = waiters.remove(at: index)
        } else {
            waiter = nil
        }
        lock.unlock()
        waiter?.continuation.resume(returning: nil)
    }

    private func compactBufferIfNeededLocked() {
        guard bufferedStart > 64, bufferedStart * 2 >= buffered.count else { return }
        buffered.removeFirst(bufferedStart)
        bufferedStart = 0
    }
}

/// Lazily creates — and then always returns — the ONE forwarding
/// `AsyncStream` adapter over an engine's FIFO.
///
/// `RecklessEngine.output` used to be a plain computed property that built a
/// fresh `AsyncStream` plus a forwarding `Task` on every access. Each access
/// therefore spawned a competing FIFO consumer: two reads of `engine.output`
/// — natural against the mirrored `StockfishEngine` API, where `output` is a
/// stored property returning the same stream — silently divided UCI lines
/// between the streams, and an accessed-then-discarded stream stole whatever
/// lines it buffered. Caching the stream here restores the Stockfish
/// semantics: every access observes the same single consumer.
///
/// Internal (not private to the engine) so the offline tests can pin the
/// single-consumer guarantee without a live Rust engine.
final class RecklessForwardedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let storage: RecklessOutputStorage
    private var cached: AsyncStream<String>?

    init(storage: RecklessOutputStorage) {
        self.storage = storage
    }

    /// The single shared adapter stream. First access creates it (spawning
    /// the one forwarding task); later accesses return the same instance.
    var stream: AsyncStream<String> {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        let source = RecklessOutput(storage: storage)
        let stream = AsyncStream<String>(bufferingPolicy: .unbounded) { continuation in
            let forwardingTask = Task {
                for await line in source {
                    guard case .enqueued = continuation.yield(line) else { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                forwardingTask.cancel()
            }
        }
        cached = stream
        return stream
    }
}

/// Ordered, single-consumer output from a ``RecklessEngine``.
///
/// Unlike `AsyncStream`, cancelling an iterator does not finish the underlying
/// engine channel. A later iterator resumes from the same FIFO. Multiple
/// simultaneous iterators divide lines between themselves, so callers must
/// still serialize logical consumers of the UCI command/output stream.
public struct RecklessOutput: AsyncSequence, Sendable {
    public typealias Element = String

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let storage: RecklessOutputStorage

        public func next() async -> String? {
            await storage.next()
        }
    }

    let storage: RecklessOutputStorage

    init(storage: RecklessOutputStorage) {
        self.storage = storage
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(storage: storage)
    }

    /// Consume the next line without retaining a mutating iterator across an
    /// actor suspension. This has the same single-consumer FIFO semantics as
    /// ``makeAsyncIterator()``.
    public func next() async -> String? {
        await storage.next()
    }
}

// Swift 6 strict concurrency: the C `stderr` global (from Android NDK stdio.h)
// is declared as a mutable variable, which the compiler flags as shared mutable
// state.  We route all diagnostic output through this nonisolated helper instead
// of calling fputs(_, stderr) directly.
@inline(__always)
private func recklessLog(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

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
///   The currently pinned fork also supports only one successful engine
///   lifetime per process; a later `init` returns `nil` rather than hanging.
public final class RecklessEngine: @unchecked Sendable {

    // Opaque Rust handle (`const void *` in C, OpaquePointer in Swift).
    private let engine: RKEngineRef

    /// Orders every send before destroy and makes explicit teardown
    /// idempotent. Without this, a send concurrent with shutdown could hand a
    /// freed opaque pointer to the C bridge.
    private let teardownLock = NSLock()
    private var isShutdown = false

    private let outputStorage = RecklessOutputStorage()

    /// Cancellation-safe, process-lifetime UCI output. Prefer this surface for
    /// consumers that cancel and restart searches on the same engine instance.
    ///
    /// - Warning: This and ``output`` are **mutually exclusive** views of one
    ///   single-consumer FIFO. Consume **only one of them** per engine instance.
    ///   Merely *accessing* ``output`` starts a forwarding consumer that competes
    ///   with this surface, silently splitting UCI lines (an awaited `bestmove`
    ///   can be diverted and lost). For concrete Reckless consumers, use this
    ///   surface and never touch ``output``.
    public var cancellationSafeOutput: RecklessOutput {
        RecklessOutput(storage: outputStorage)
    }

    private let forwardedOutput: RecklessForwardedOutput

    /// An async stream of UCI output lines from the engine, in order.
    ///
    /// Lines are delivered without their trailing newline.  The stream is
    /// unbounded-buffered; iterate it promptly if you care about back-pressure.
    /// It finishes when the engine is destroyed (`deinit` / ``shutdown()``).
    /// Compatibility adapter for the shared `UCIEngine` protocol, matching
    /// `StockfishEngine.output`'s stored-property semantics: every access
    /// returns the SAME stream (the single forwarding consumer is created on
    /// first access), so repeated access never spawns a competing FIFO
    /// consumer. Cancelling it cancels only its forwarding waiter in
    /// ``cancellationSafeOutput``, not the engine channel — but like any
    /// `AsyncStream` it is single-consumer and cannot be restarted; restarting
    /// concrete Reckless consumers should use ``cancellationSafeOutput``
    /// directly.
    ///
    /// - Warning: This is a compatibility shim for the shared `UCIEngine`
    ///   protocol and is **mutually exclusive** with ``cancellationSafeOutput``
    ///   (both drain the same single-consumer FIFO). The forwarding consumer
    ///   starts on the **first access** to this property — so even touching it
    ///   once while another part of the app drives ``cancellationSafeOutput``
    ///   splits the UCI output between the two. Pick one surface per engine.
    public var output: AsyncStream<String> {
        forwardedOutput.stream
    }

    /// Create and start a Reckless engine instance.
    ///
    /// - Parameter networkDirectory: A directory that already contains
    ///   `v54-5478683c.nnue` (the required NNUE net).  Use
    ///   ``RecklessNetworkLoader/ensure(in:progress:)`` to provision it.
    ///
    /// - Returns: `nil` if the net file is not present in `networkDirectory`,
    ///   if the Rust FFI layer could not start it, or if this process already
    ///   used its one engine lifetime under the currently pinned fork.
    public init?(networkDirectory: URL) {
        // One cached adapter per engine (creating the box spawns no task;
        // the forwarding consumer starts on `output`'s first access).
        self.forwardedOutput = RecklessForwardedOutput(storage: outputStorage)

        // Build the full path to the net file and verify it exists before
        // handing it to the Rust FFI (which returns NULL on failure, but
        // an explicit pre-check gives a clearer early-out).
        let netFile = networkDirectory.appendingPathComponent(
            RecklessNetworkLoader.network.filename
        )
        guard FileManager.default.fileExists(atPath: netFile.path) else {
            recklessLog("[RecklessEngine] net file not found: \(netFile.path)")
            outputStorage.finish()
            return nil
        }

        guard let ref = netFile.path.withCString({ rk_create($0) }) else {
            outputStorage.finish()
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
            me.outputStorage.yield(line)
        }, context)
    }

    deinit {
        shutdown()
    }

    // MARK: - Raw UCI

    /// Send a raw UCI command string (no trailing newline needed).
    public func send(_ command: String) {
        teardownLock.lock()
        defer { teardownLock.unlock() }
        guard !isShutdown else { return }
        command.withCString { rk_send_command(engine, $0) }
    }

    /// Destroy the engine, join its background thread, and finish ``output``.
    /// Idempotent and safe to race with ``send(_:)``. The join can block while
    /// a search winds down, so call this from a background context rather than
    /// the main actor when deterministic teardown timing matters.
    public func shutdown() {
        teardownLock.lock()
        defer { teardownLock.unlock() }
        guard !isShutdown else { return }
        isShutdown = true
        rk_destroy(engine)
        outputStorage.finish()
    }

    // MARK: - Convenience UCI commands

    /// Send `uci`.  The engine replies with its `id`/`option` lines then `uciok`.
    public func uci() { send("uci") }

    /// Send `isready`.  The engine replies `readyok` once all pending work is done.
    public func isReady() { send("isready") }

    /// Send `ucinewgame` to reset hash tables and engine state for a new game.
    public func newGame() { send("ucinewgame") }

    /// Send `quit`, asking the UCI loop to exit.
    /// This is a UCI command only; call ``shutdown()`` to synchronously join
    /// the thread and release its resources.
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
