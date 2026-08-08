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
//   * One `RKEngineRef` at a time — the Rust engine owns process-global state
//     (look-up tables, NNUE weights) that cannot safely run in parallel, so
//     overlapping engines are rejected. Repeated SEQUENTIAL lifetimes are
//     supported (fork swiftreckless-v0.9.1+): a clean `rk_destroy` unloads the
//     ~60 MB net and releases the lifetime slot, and the next `rk_create`
//     reloads the net from disk. A failed startup whose engine thread could
//     not be joined poisons the slot for the rest of the process.
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
///   * At most ONE engine is live at a time (an overlapping `rk_create`
///     returns NULL). Sequential lifetimes are supported: after a clean
///     `rk_destroy`, a later `rk_create` starts a fresh engine with a freshly
///     loaded net.
///   * Call `rk_destroy` EXACTLY ONCE per non-NULL `rk_create`. A second
///     `rk_destroy` on the same handle is a double-free / use-after-free, and any
///     `rk_send_command` / `rk_set_output_callback` after `rk_destroy`
///     dereferences freed memory — undefined behavior; the handle is dangling
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
/// another engine is live, or a previous failed startup left its engine
/// thread unjoined (which poisons the process's engine slot).
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

/// Report whether this build linked the REAL Reckless engine or the no-op
/// host stubs.
///
/// Returns 0 when the four `rk_*` entry points above reach a real engine, and 1
/// when they reach `RecklessHostStubs.c`, whose `rk_create` always returns NULL.
///
/// WHY THIS EXISTS. The package has a legitimate stub configuration — the
/// Skip/Gradle host-introspection pass must link without the Android ELF
/// archive, and a Linux/Windows consumer that has supplied no archive must
/// still build. What is NOT acceptable is being unable to tell the two apart:
/// a stub build otherwise looks exactly like a real build whose NNUE net is
/// missing. Check this (or Swift's `RecklessBackend.current`) before concluding
/// that an engine failure is a data problem.
///
/// This is a COMPILE-TIME constant baked in by the arm that built CReckless; it
/// performs no work and is safe to call at any time, including before
/// `rk_create`.
int rk_backend_is_stub(void);

#ifdef __cplusplus
}
#endif

#endif /* RECKLESS_BRIDGE_H */
