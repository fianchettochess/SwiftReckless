# C FFI bridge

SwiftReckless drives the Reckless chess engine (written in Rust) in-process via a
three-layer bridge: a Rust FFI crate, a thin C shim, and the Swift wrapper. No
subprocess is spawned; the engine runs on a background thread inside the host process.

## Three-layer design

| Layer | Target | Role |
|---|---|---|
| Rust crate (`creckless`) | `crate-type = ["staticlib", "rlib"]` | Runs Reckless's UCI loop on a background thread; exposes 4 `extern "C"` symbols with the `rk_ffi_*` prefix |
| C shim (`CReckless`) | SPM module | `RecklessBridge.c` forwards `rk_*` → `rk_ffi_*`; `RecklessHostStubs.c` supplies no-op `rk_ffi_*` on non-Android source-arm hosts; the public C header is the Swift module boundary |
| Swift (`SwiftReckless`) | SPM module | `RecklessEngine` wraps `RKEngineRef`; `AsyncStream` output; `RecklessNetworkLoader`; mirrors `StockfishEngine` |

## The C header (`RecklessBridge.h`)

The public Swift module interface consists of four C declarations:

```c
/// Opaque handle to a live Reckless engine instance.
typedef const void *RKEngineRef;

/// Callback invoked (on the engine thread) for each UCI output line.
/// `line`    — NUL-terminated UTF-8 string, without trailing newline. A NULL
///             `line` is a sentinel meaning the engine thread has exited
///             (normal quit or contained panic) — treat it as end-of-output,
///             not a line.
/// `context` — the opaque pointer passed to rk_set_output_callback.
typedef void (*RKOutputCallback)(const char *line, const void *context);

/// Create and start a Reckless engine instance.
/// `network_path` — full path to the NNUE file; returns NULL if missing or unreadable.
RKEngineRef rk_create(const char *network_path);

/// Destroy the engine, joining its thread and freeing all resources. Safe with NULL.
void rk_destroy(RKEngineRef engine);

/// Register a callback for UCI output lines. Thread-safe.
void rk_set_output_callback(RKEngineRef engine,
                             RKOutputCallback callback,
                             const void *context);

/// Send a UCI command to the engine's input queue (no trailing newline needed). Thread-safe.
void rk_send_command(RKEngineRef engine, const char *command);
```

## The Rust implementation (`rust/src/ffi.rs`)

The Rust crate exports identical symbols with the `rk_ffi_*` prefix to avoid
colliding with any system `rk_*` names. `RecklessBridge.c` is a thin shim that
re-exports them as the cleaner `rk_*` names seen by Swift:

```c
// RecklessBridge.c (simplified)
RKEngineRef rk_create(const char *network_path) { return rk_ffi_create(network_path); }
void        rk_destroy(RKEngineRef e)            { rk_ffi_destroy(e); }
void        rk_set_output_callback(...)          { rk_ffi_set_output_callback(...); }
void        rk_send_command(...)                 { rk_ffi_send_command(...); }
```

`rk_ffi_create` (and therefore `rk_create`):

1. Loads the NNUE network from `network_path` via `reckless::nnue::load_network`.
2. Creates an `mpsc::channel` for command delivery.
3. Spawns a named background thread running `reckless::run_io(initial_cmds, rx, output_sink)`.
4. Returns an opaque heap-allocated handle (`*const RkEngine` cast to `*const c_void`).

## Threading model

- The engine's UCI loop runs on a **dedicated background thread** inside the Rust
  crate. Swift never needs to manage its own thread for the engine.
- Input is delivered via `mpsc::Sender`; `rk_send_command` is therefore thread-safe
  (it only calls `Sender::send`).
- Each UCI output line fires the registered `RKOutputCallback` on the engine
  thread or a search-worker thread. `RecklessEngine` feeds its lock-protected
  output FIFO (`RecklessOutputStorage`) from the callback, so callers must not
  assume a particular callback thread or call back into `rk_ffi_*` from it.
- `rk_destroy` sends `"quit"`, drops the `Sender` (causing `run_io` to observe
  channel closure), and `join()`s the thread. After it returns, the callback can
  never fire — there is no use-after-free window.

## I/O model: no stdout/fd redirection

Unlike `CStockfish` in SwiftStockfish — which swaps `std::cin`/`std::cout` stream
buffers — the Reckless bridge uses **per-instance callback delivery with no
stdout/fd redirection**. There is no global stream manipulation; all I/O flows
through the `mpsc` channel and the C callback registered via `rk_set_output_callback`.

This design eliminates the class of bugs caused by a leaked stream-buffer swap.
The pinned fork supports create→destroy→create-again lifecycles; overlap remains
prohibited because the engine owns process-global tables and NNUE state. See
[Engine API → Teardown sequence](engine-api.md#teardown-sequence).

## Swift-to-C mapping in `RecklessEngine`

```swift
// init(networkDirectory:)
let ref = netFile.path.withCString { rk_create($0) }   // → RKEngineRef (OpaquePointer)

// Register callback — bridge `self` as an unretained void*
let context = Unmanaged.passUnretained(self).toOpaque()
rk_set_output_callback(engine, { linePtr, ctx in
    guard let ctx else { return }
    let me = Unmanaged<RecklessEngine>.fromOpaque(ctx).takeUnretainedValue()
    guard let linePtr else {
        // NULL line = the engine-thread-exit sentinel (normal quit or a
        // contained Rust panic): finish the output channel so consumers
        // receive EOF instead of hanging.
        me.outputStorage.finish()
        return
    }
    me.outputStorage.yield(String(cString: linePtr))
}, context)

// send(_:)
command.withCString { rk_send_command(engine, $0) }

// Teardown: shutdown() — idempotent (teardown lock + isShutdown flag);
// deinit merely calls it if explicit teardown was omitted.
rk_destroy(engine)
outputStorage.finish()
```

The callback yields into `RecklessOutputStorage` — the lock-protected FIFO behind
`cancellationSafeOutput` and the `output` adapter — not into a bare
`AsyncStream.Continuation`. The unretained pointer is safe because `shutdown()`
(called by `deinit` at the latest) calls `rk_destroy` (which joins the engine
thread) before `self` is deallocated, guaranteeing the callback cannot fire
against a freed object.

## `RecklessHostStubs.c`

In the source arm on non-Android hosts, the real `rk_ffi_*` symbols from the Rust
staticlib are not linked. `RecklessHostStubs.c` provides no-op implementations:

```c
// RecklessHostStubs.c (simplified)
RKEngineRef rk_ffi_create(const char *_)    { return NULL; }
void        rk_ffi_destroy(RKEngineRef _)   {}
void        rk_ffi_set_output_callback(...) {}
void        rk_ffi_send_command(...)        {}
```

This lets the Skip/Gradle host-introspection pass link the package cleanly on a
non-Android host without needing an Android NDK or a cross-compiled staticlib.

## See also

- [Build model](build-model.md) — which arm links which objects, and when.
- [Engine API](engine-api.md) — the Swift wrapper over this bridge.
