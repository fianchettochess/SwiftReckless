#ifndef RECKLESS_BRIDGE_H
#define RECKLESS_BRIDGE_H

// CReckless — C interop header for SwiftReckless.
//
// This is the Swift module's public C interface.  Swift imports this header via
// the `CReckless` module and calls these four functions to drive Reckless's UCI
// loop in-process.
//
// THREADING MODEL (mirrors SwiftStockfish / CStockfish):
//   * `rk_create` spawns a background thread that runs the Reckless UCI loop.
//     The loop reads from an internal thread-safe queue (fed by `rk_send_command`)
//     and writes to a callback (set by `rk_set_output_callback`).
//   * One `RKEngineRef` per process — the Rust engine owns process-global state
//     (look-up tables, NNUE weights) that cannot safely run in parallel. The
//     pinned fork's lookup initialization is not restart-safe, so the bridge
//     currently rejects overlap and any second engine lifetime in one process.
//   * `rk_destroy` sends "quit", joins the engine thread, and frees all memory.
//     After it returns no further callbacks can fire.
//
// ABI NOTE: the Rust FFI crate (`rust/`) exposes identical symbols with the
// `rk_ffi_*` prefix (to avoid colliding with any system `rk_*`); the C bridge
// in RecklessBridge.c is a thin forwarding shim that gives them the cleaner
// `rk_*` names seen here.  See rust/src/ffi.rs for the Rust declarations.

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to a live Reckless engine instance.
///
/// CONTRACT for direct CReckless consumers (the Swift `RecklessEngine` wrapper
/// upholds all of this internally, so Swift API users need not care):
///   * At most ONE engine is live per process, and the pinned fork supports only
///     one successful engine LIFETIME per process (a later `rk_create` returns
///     NULL rather than restarting).
///   * Call `rk_destroy` EXACTLY ONCE per non-NULL `rk_create`. A second
///     `rk_destroy` on the same handle is a double-free / use-after-free, and any
///     `rk_send_command` / `rk_set_output_callback` after `rk_destroy`
///     dereferences freed memory — undefined behaviour; the handle is dangling
///     once destroyed.
///   * Do not call these concurrently on the same handle; serialize them.
///   * NULL handles and a NULL `command` are defensively no-ops; every other
///     misuse above is caller responsibility.
typedef const void *RKEngineRef;

/// Callback invoked (on the engine thread) for each UCI output line.
/// `line`    — NUL-terminated UTF-8 string, without trailing newline. A NULL
///             `line` is a SENTINEL meaning the engine thread has EXITED (a
///             normal quit or a contained panic): treat it as end-of-output, not
///             a line, so a consumer awaiting output receives EOF instead of
///             hanging.
/// `context` — the opaque pointer passed to `rk_set_output_callback`.
typedef void (*RKOutputCallback)(const char *line, const void *context);

/// Create and start a Reckless engine instance.
///
/// `network_path` — NUL-terminated path to the NNUE network file
///                  (`v54-5478683c.nnue`).  Must be non-NULL and exist before
///                  calling: `rk_create` loads the net at runtime and returns
///                  NULL if the path is NULL, missing, or unreadable. (The fork
///                  removed upstream's compile-time embed, so a net path is
///                  always required.)
///
/// Returns a non-NULL handle on success, NULL if engine initialisation failed,
/// another engine is live, or this process already completed an engine lifetime
/// under the currently pinned non-restart-safe Reckless fork.
RKEngineRef rk_create(const char *network_path);

/// Destroy the engine, joining its thread and freeing all resources.
/// Safe to call with NULL.
void rk_destroy(RKEngineRef engine);

/// Register a callback for UCI output lines.
/// Must be called before the engine's UCI loop starts processing commands.
/// Thread-safe: can be called from any thread while the engine is running,
/// but no ordering guarantee with in-flight output lines.
void rk_set_output_callback(RKEngineRef engine,
                             RKOutputCallback callback,
                             const void *context);

/// Send a UCI command to the engine's input queue (no trailing newline needed).
/// Thread-safe: can be called from any thread.
void rk_send_command(RKEngineRef engine, const char *command);

#ifdef __cplusplus
}
#endif

#endif /* RECKLESS_BRIDGE_H */
