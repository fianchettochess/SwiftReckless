// RecklessBridge.c — thin C shim that forwards rk_* calls to the Rust FFI
// crate's rk_ffi_* symbols.
//
// WHY A SHIM?
//   Rust cdylib/staticlib symbols must start with a legal C identifier, and
//   we want to keep the public Swift-facing names clean (`rk_create` etc.).
//   The Rust crate uses the `rk_ffi_` prefix internally to avoid any possible
//   name collision with system libraries; this shim gives the four functions
//   their final public names and is the ONLY file in CReckless that the Swift
//   compiler's C module imports directly.
//
// STATUS: wired — these functions forward to the real rk_ffi_* bodies in
//   rust/src/ffi.rs, which drive the Reckless engine (a maintained-fork git
//   dependency) in-process.

#include "RecklessBridge.h"
#include <stddef.h>

// ── Rust FFI symbols (rk_ffi_* prefix) ───────────────────────────────────────
// Declared here so this translation unit can link them from the Rust staticlib
// without a separate header.  The definitions live in rust/src/ffi.rs.

extern RKEngineRef rk_ffi_create(const char *network_path);
extern void        rk_ffi_destroy(RKEngineRef engine);
extern void        rk_ffi_set_output_callback(RKEngineRef engine,
                                               RKOutputCallback callback,
                                               const void *context);
extern void        rk_ffi_send_command(RKEngineRef engine, const char *command);

// ── Public rk_* shims ────────────────────────────────────────────────────────

RKEngineRef rk_create(const char *network_path) {
    return rk_ffi_create(network_path);
}

void rk_destroy(RKEngineRef engine) {
    rk_ffi_destroy(engine);
}

void rk_set_output_callback(RKEngineRef engine,
                             RKOutputCallback callback,
                             const void *context) {
    rk_ffi_set_output_callback(engine, callback, context);
}

void rk_send_command(RKEngineRef engine, const char *command) {
    rk_ffi_send_command(engine, command);
}
