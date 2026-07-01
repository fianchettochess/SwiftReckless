// creckless/src/ffi.rs
//
// C FFI surface for the SwiftReckless bridge.
//
// THREADING MODEL (mirrors StockfishBridge.cpp in CStockfish):
//
//   rk_ffi_create  — allocates an `EngineState` on the heap, spawns a
//                    background `std::thread` that runs the Reckless UCI
//                    message loop (feeding it from a `mpsc` channel), and
//                    returns a `*mut EngineState` as the opaque `RKEngineRef`.
//
//   rk_ffi_send_command — sends a String across the channel to the engine
//                         thread.  Thread-safe (Sender is Send).
//
//   rk_ffi_set_output_callback — stores a C function pointer + context that
//                                is called from the engine thread for every
//                                UCI output line.
//
//   rk_ffi_destroy — sends "quit", drops the Sender (closing the channel),
//                    and joins the engine thread, then drops the Box<EngineState>.
//                    After join() returns no further callbacks can fire.
//
// OUTPUT DELIVERY: Reckless's UCI loop writes to stdout.  We intercept this
// by running the loop in a thread that has its stdout replaced by a custom
// write-half that calls our callback instead of writing to fd 1.  Until the
// real engine is wired in, the stub thread simply parks and returns immediately
// when "quit" is received.
//
// STATUS: STUBBED — `rk_ffi_create` always returns NULL (safe failure) so
// `RecklessEngine.init?(networkFile:)` returns nil and the app can detect the
// unavailability gracefully.  Wire in the Reckless engine crate (see
// Cargo.toml) and replace the stub bodies to activate.

use libc::{c_char, c_void};
use std::ffi::CStr;
use std::sync::mpsc;
use std::thread;

// ── Types ─────────────────────────────────────────────────────────────────────

/// C-visible callback type (matches RecklessBridge.h).
pub type RKOutputCallback =
    Option<unsafe extern "C" fn(line: *const c_char, context: *const c_void)>;

/// Heap-allocated engine state.  Owned by the caller between
/// `rk_ffi_create` and `rk_ffi_destroy`.
struct EngineState {
    /// Channel sender: push UCI command strings to the engine thread.
    sender: mpsc::Sender<String>,
    /// Engine thread handle; joined in `rk_ffi_destroy`.
    handle: Option<thread::JoinHandle<()>>,
    /// Output callback registered by `rk_ffi_set_output_callback`.
    callback: RKOutputCallback,
    callback_context: *const c_void,
}

// SAFETY: `callback_context` is an opaque `void *` managed by the Swift
// caller.  SwiftReckless ensures the pointed-to object outlives the engine
// (same contract as in StockfishBridge.cpp).  We declare Sync/Send manually
// since `*const c_void` is not Send by default.
unsafe impl Send for EngineState {}
unsafe impl Sync for EngineState {}

// ── FFI functions (rk_ffi_* prefix) ──────────────────────────────────────────

/// Create and start a Reckless engine instance.
///
/// # Safety
/// `network_path` must be a valid NUL-terminated C string (or NULL).
/// The returned pointer must be passed to `rk_ffi_destroy` exactly once.
#[no_mangle]
pub unsafe extern "C" fn rk_ffi_create(network_path: *const c_char) -> *mut c_void {
    // Log the network path for diagnostics (debug builds only).
    #[cfg(debug_assertions)]
    {
        let path = if network_path.is_null() {
            "(null — using compiled-in default)".to_owned()
        } else {
            CStr::from_ptr(network_path)
                .to_str()
                .unwrap_or("<invalid utf-8>")
                .to_owned()
        };
        eprintln!("[SwiftReckless] rk_ffi_create: network_path={path}");
    }
    let _ = network_path; // suppress unused warning in release

    // ── STUB ──────────────────────────────────────────────────────────────────
    // TODO: Replace this stub with real engine initialisation once the
    // `reckless` crate is wired in:
    //
    //   1. Add to rust/Cargo.toml:
    //      [dependencies]
    //      reckless = { git = "https://github.com/codedeliveryservice/Reckless.git", tag = "v0.9.0" }
    //
    //   2. Replace the stub thread body below with:
    //      reckless::run(VecDeque::new());  // blocks until "quit"
    //
    //   3. Intercept Reckless's stdout output to call `output_callback`
    //      instead of writing to fd 1.  Options:
    //        a) Redirect stdout via a pipe before calling run().
    //        b) Patch reckless::run() to accept a Write impl (upstream PR).
    //
    // ─────────────────────────────────────────────────────────────────────────
    //
    // For now, return NULL so RecklessEngine.init? returns nil gracefully.
    eprintln!("[SwiftReckless] STUB: rk_ffi_create returning NULL — engine not yet wired in");
    std::ptr::null_mut()

    // ── REAL IMPLEMENTATION TEMPLATE (uncomment when engine is wired) ─────────
    // let (sender, receiver) = mpsc::channel::<String>();
    //
    // let handle = thread::Builder::new()
    //     .name("reckless-uci".into())
    //     .stack_size(4 * 1024 * 1024) // 4 MB, matching CStockfish's iOS limit
    //     .spawn(move || {
    //         // TODO: redirect stdout to callback before calling run().
    //         let mut buffer = std::collections::VecDeque::new();
    //         // Drain any commands that arrived before the thread started.
    //         while let Ok(cmd) = receiver.try_recv() {
    //             if cmd == "quit" { return; }
    //             buffer.push_back(cmd);
    //         }
    //         reckless::run(buffer);
    //         // After run() returns, drain any trailing commands.
    //         drop(receiver);
    //     })
    //     .expect("failed to spawn reckless-uci thread");
    //
    // let state = Box::new(EngineState {
    //     sender,
    //     handle: Some(handle),
    //     callback: None,
    //     callback_context: std::ptr::null(),
    // });
    // Box::into_raw(state) as *mut c_void
}

/// Destroy the engine, joining its thread and freeing all resources.
///
/// # Safety
/// `engine` must be a pointer previously returned by `rk_ffi_create`
/// (non-NULL), and must not be used again after this call.
#[no_mangle]
pub unsafe extern "C" fn rk_ffi_destroy(engine: *mut c_void) {
    if engine.is_null() {
        return;
    }
    let mut state = Box::from_raw(engine as *mut EngineState);
    // Signal shutdown: send "quit" then drop the Sender (closes channel).
    let _ = state.sender.send("quit".to_owned());
    drop(state.sender.clone()); // keep a clone; original moves into the Box

    // Join the engine thread.
    if let Some(handle) = state.handle.take() {
        let _ = handle.join();
    }
    // `state` drops here, freeing the EngineState.
}

/// Register a callback for UCI output lines.
///
/// # Safety
/// `engine` must be non-NULL and valid.  `context` must remain valid until
/// `rk_ffi_destroy` is called.
#[no_mangle]
pub unsafe extern "C" fn rk_ffi_set_output_callback(
    engine: *mut c_void,
    callback: RKOutputCallback,
    context: *const c_void,
) {
    if engine.is_null() {
        return;
    }
    let state = &mut *(engine as *mut EngineState);
    state.callback = callback;
    state.callback_context = context;
}

/// Send a UCI command to the engine's input queue.
///
/// # Safety
/// `engine` must be non-NULL and valid.  `command` must be a valid
/// NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn rk_ffi_send_command(engine: *mut c_void, command: *const c_char) {
    if engine.is_null() || command.is_null() {
        return;
    }
    let state = &*(engine as *mut EngineState);
    if let Ok(cmd) = CStr::from_ptr(command).to_str() {
        let _ = state.sender.send(cmd.to_owned());
    }
}

// ── Internal helper: deliver one output line to the registered callback ───────
//
// Called from the engine thread once the real implementation is wired.
// Strips trailing '\n' and '\r', then calls the C function pointer.
#[allow(dead_code)]
unsafe fn deliver_line(state: &EngineState, line: &str) {
    let line = line.trim_end_matches(['\n', '\r']);
    if line.is_empty() {
        return;
    }
    if let Some(cb) = state.callback {
        // Build a temporary NUL-terminated C string on the stack.
        let mut buf = line.to_owned();
        buf.push('\0');
        cb(buf.as_ptr() as *const c_char, state.callback_context);
    }
}
