// creckless/src/ffi.rs
//
// C FFI surface for the SwiftReckless bridge.
//
// ── Threading model ──────────────────────────────────────────────────────────
//
// PER-INSTANCE I/O — LIFECYCLES SERIALIZED
// Each engine instance owns an mpsc channel (Sender in EngineState; Receiver
// passed into reckless::run_io on a dedicated thread).  UCI output is routed
// through an Arc<Mutex<SharedCallback>> that the engine thread captures in a
// closure.  There is NO fd redirection, NO dup2, NO pipe — fd 0 and fd 1 are
// never touched.  The app's stdout is free for the lifetime of the engine.
//
// rk_ffi_create:
//   0. Acquire a process-wide lifecycle lease. I/O is per-instance, but the
//      engine's NNUE weights/tables are global and overlapping searches are not
//      safe. The pinned fork's lookup initialization is also non-idempotent, so
//      a second successful engine lifetime is rejected until that fork is fixed.
//   1. Create an mpsc channel (tx stored in EngineState; rx consumed by the
//      engine thread).
//   2. Create Arc<Mutex<SharedCallback>> shared between EngineState and the
//      output closure.
//   3. Spawn ONE engine thread: calls reckless::run_io(VecDeque::new(), rx,
//      Box::new(move |line| { /* look up C callback + call it */ })).
//      This thread blocks reading from the channel until "quit" or channel close.
//
// rk_ffi_send_command:
//   tx.send(cmd_string) — thread-safe by mpsc contract.
//
// rk_ffi_set_output_callback:
//   Store callback+context into the shared Arc<Mutex<SharedCallback>>.  Lines
//   that arrive before the callback is set are dropped (same contract as the
//   old fd-redirect model).
//
// rk_ffi_destroy — SHUTDOWN ORDER (deadlock-free reasoning):
//   A. Send "quit" through the channel.  reckless::run_io's message loop reads
//      it, breaks, and run_io returns, clearing the output sink.  Engine thread
//      exits.
//   B. Drop the Sender (closes the channel).  Backup in case "quit" was already
//      processed; also guarantees the channel is closed so run_io sees
//      Err(RecvError) if the quit message raced.
//   C. Join the engine thread.  After join all UCI output has been delivered.
//   D. Drop the Box<EngineState> — resources freed.
//
//   WHY THIS ORDER IS DEADLOCK-FREE:
//   - The engine thread only blocks on channel recv() or search.  It holds no
//     lock that the destructor needs.
//   - The output closure holds Arc<Mutex<SharedCallback>>.  The closure fires
//     from inside run_io on the engine thread.  We join the engine thread before
//     dropping EngineState, so the Arc refcount reaches zero safely.
//   - No fd manipulation means no risk of restoring the wrong fd or racing with
//     another process that also manipulates fd 0/1.
//
// CALLBACK ORDERING:
//   Same as the old model: the app sets the callback after rk_ffi_create and
//   before sending any command that produces output.

use libc::{c_char, c_void};
use std::collections::VecDeque;
use std::ffi::{CStr, CString};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::Duration;

// ── Types ─────────────────────────────────────────────────────────────────────

/// C-visible callback type (matches RecklessBridge.h).
pub type RKOutputCallback =
    Option<unsafe extern "C" fn(line: *const c_char, context: *const c_void)>;

/// Shared between EngineState and the output closure on the engine thread.
struct SharedCallback {
    callback: RKOutputCallback,
    callback_context: *const c_void,
}

// SAFETY: callback_context is an opaque void* managed by the Swift caller.
// SwiftReckless guarantees the pointed-to object outlives the engine
// (same contract as StockfishBridge.cpp).
unsafe impl Send for SharedCallback {}
unsafe impl Sync for SharedCallback {}

/// Heap-allocated engine state.  Owned by the caller between
/// rk_ffi_create and rk_ffi_destroy.
struct EngineState {
    /// Sender half of the command channel.  Send UCI command strings here.
    sender: Mutex<Option<std::sync::mpsc::Sender<String>>>,
    /// Engine thread handle.
    engine_handle: Option<thread::JoinHandle<()>>,
    /// Shared callback state (also held by the engine thread's output closure).
    shared_cb: Arc<Mutex<SharedCallback>>,
    /// Held from create until the engine thread is joined and state is freed.
    /// Reckless's NNUE weights/tables are process-global even though I/O is
    /// per-instance, so overlapping engines are not safe.
    _lifecycle_lease: LifecycleLease,
}

// SAFETY: See SharedCallback above.
unsafe impl Send for EngineState {}
unsafe impl Sync for EngineState {}

// ── Process-wide engine lifecycle gate ───────────────────────────────────────

struct LifecycleState {
    live: bool,
    /// The pinned Reckless fork's lookup::initialize() is not idempotent:
    /// its second init_cuckoo() runs against populated tables and can loop
    /// forever. Until that fork guards lookup + NNUE threat initialization
    /// with std::sync::Once, one successful run_io lifetime is the safe limit.
    has_started_once: bool,
}

struct LifecycleGate {
    state: Mutex<LifecycleState>,
}

impl LifecycleGate {
    fn try_acquire(&'static self) -> Option<LifecycleLease> {
        let mut state = self.state.lock().unwrap();
        if state.live || state.has_started_once {
            return None;
        }
        state.live = true;
        Some(LifecycleLease { gate: self })
    }

    fn mark_started(&self) {
        self.state.lock().unwrap().has_started_once = true;
    }

    fn release(&self) {
        self.state.lock().unwrap().live = false;
    }
}

fn lifecycle_gate() -> &'static LifecycleGate {
    static GATE: OnceLock<LifecycleGate> = OnceLock::new();
    GATE.get_or_init(|| LifecycleGate {
        state: Mutex::new(LifecycleState {
            live: false,
            has_started_once: false,
        }),
    })
}

struct LifecycleLease {
    gate: &'static LifecycleGate,
}

impl LifecycleLease {
    fn mark_started(&self) {
        self.gate.mark_started();
    }
}

impl Drop for LifecycleLease {
    fn drop(&mut self) {
        self.gate.release();
    }
}

// ── FFI functions (rk_ffi_* prefix) ──────────────────────────────────────────

/// Create and start a Reckless engine instance.
///
/// `network_path` must be a valid NUL-terminated C string pointing to the
/// Reckless NNUE net file (e.g. "v54-5478683c.nnue").  NULL is not accepted.
///
/// Returns an opaque non-NULL pointer on success, NULL on failure.
/// The returned pointer must be passed to rk_ffi_destroy exactly once.
///
/// # Safety
/// `network_path` must be a valid NUL-terminated C string (not NULL).
#[no_mangle]
pub unsafe extern "C" fn rk_ffi_create(network_path: *const c_char) -> *mut c_void {
    // ── 0. Load NNUE net from the supplied path ───────────────────────────────
    if network_path.is_null() {
        eprintln!("[creckless] rk_ffi_create: network_path is NULL — net is required");
        return std::ptr::null_mut();
    }
    let net_path_str = match CStr::from_ptr(network_path).to_str() {
        Ok(s) => s.to_owned(),
        Err(_) => {
            eprintln!("[creckless] rk_ffi_create: network_path is not valid UTF-8");
            return std::ptr::null_mut();
        }
    };
    // Reject overlap and a second successful engine lifetime before touching
    // the process-global tables. The latter is a fail-fast containment for the
    // pinned fork's non-idempotent lookup initializer; see LifecycleState.
    let lifecycle_lease = match lifecycle_gate().try_acquire() {
        Some(lease) => lease,
        None => {
            eprintln!(
                "[creckless] rk_ffi_create: engine lifetime unavailable; \
                 the pinned Reckless fork currently supports one run per process"
            );
            return std::ptr::null_mut();
        }
    };
    eprintln!("[creckless] rk_ffi_create: loading NNUE net from {net_path_str}");
    let net_bytes = match std::fs::read(&net_path_str) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("[creckless] rk_ffi_create: failed to read net file '{net_path_str}': {e}");
            return std::ptr::null_mut();
        }
    };
    match reckless::nnue::load_network(&net_bytes) {
        Ok(()) => eprintln!(
            "[creckless] rk_ffi_create: NNUE net loaded ({} bytes)",
            net_bytes.len()
        ),
        Err(e) => {
            if e.contains("already loaded") {
                eprintln!("[creckless] rk_ffi_create: NNUE net already loaded, continuing");
            } else {
                eprintln!("[creckless] rk_ffi_create: load_network failed: {e}");
                return std::ptr::null_mut();
            }
        }
    }

    // ── 1. Create the command channel ─────────────────────────────────────────
    let (tx, rx) = std::sync::mpsc::channel::<String>();

    // ── 2. Shared callback state ──────────────────────────────────────────────
    let shared_cb = Arc::new(Mutex::new(SharedCallback {
        callback: None,
        callback_context: std::ptr::null(),
    }));
    let shared_cb_engine = Arc::clone(&shared_cb);
    // `rk_ffi_create` must not return while run_io is still constructing its
    // worker pool. An immediate destroy in that window exposed a Reckless
    // startup/teardown race that could hang the join. A private isready probe
    // gives us an unambiguous "message loop is live" handshake.
    let (startup_ready_tx, startup_ready_rx) = std::sync::mpsc::channel::<()>();

    // ── 3. Spawn engine thread ────────────────────────────────────────────────
    // reckless::run_io blocks until "quit" or channel close.
    // The output closure captures shared_cb_engine and fires for every UCI line.
    let engine_handle = thread::Builder::new()
        .name("reckless-uci".into())
        .stack_size(8 * 1024 * 1024) // 8 MB — search is stack-heavy
        .spawn(move || {
            reckless::run_io(
                VecDeque::new(),
                rx,
                Box::new(move |line: &str| {
                    if line == "readyok" {
                        // The receiver is dropped after create completes. Later
                        // client isready replies simply make this send fail.
                        let _ = startup_ready_tx.send(());
                    }
                    let cb_guard = shared_cb_engine.lock().unwrap();
                    if let Some(cb) = cb_guard.callback {
                        if let Ok(cstr) = CString::new(line) {
                            let ctx = cb_guard.callback_context;
                            // Drop the lock before calling into C to avoid
                            // holding it during the (potentially slow) callback.
                            drop(cb_guard);
                            // SAFETY: cstr is valid; ctx outlives the engine per
                            // the Swift caller's contract.
                            unsafe { cb(cstr.as_ptr(), ctx) };
                        }
                    }
                    // else: no callback installed yet; drop the line silently.
                }),
            );
        })
        .expect("[creckless] failed to spawn reckless-uci thread");

    // Once run_io has been spawned it may already have entered the pinned
    // engine's non-idempotent process-global initialization, even if it exits
    // before answering isready. Consume the one-lifetime slot immediately so
    // an early startup failure can never make a second unsafe attempt.
    lifecycle_lease.mark_started();

    if tx.send("isready".to_string()).is_err()
        || startup_ready_rx
            .recv_timeout(Duration::from_secs(30))
            .is_err()
    {
        eprintln!("[creckless] rk_ffi_create: engine startup handshake failed");
        let _ = tx.send("quit".to_string());
        drop(tx);
        if engine_handle.is_finished() {
            let _ = engine_handle.join();
        } else {
            // Rust has no safe way to kill a stuck thread. Detach it so the C
            // caller receives NULL after the bounded timeout, and permanently
            // consume the process lifecycle slot so no later engine can race
            // the still-running initializer. Closing tx above lets a merely
            // slow (not stuck) loop observe EOF and exit eventually.
            std::mem::forget(lifecycle_lease);
            drop(engine_handle);
        }
        return std::ptr::null_mut();
    }

    // ── 4. Box up state and return ────────────────────────────────────────────
    let state = Box::new(EngineState {
        sender: Mutex::new(Some(tx)),
        engine_handle: Some(engine_handle),
        shared_cb,
        _lifecycle_lease: lifecycle_lease,
    });

    eprintln!("[creckless] rk_ffi_create: engine started (per-instance I/O, no fd redirect)");
    Box::into_raw(state) as *mut c_void
}

/// Destroy the engine: clean shutdown, no hangs.
///
/// Shutdown order:
///   1. Send "quit" through the channel.
///   2. Drop the Sender (close the channel — backup EOF signal).
///   3. Join the engine thread.
///   4. Free Box<EngineState>.
///
/// # Safety
/// `engine` must be a pointer previously returned by rk_ffi_create (non-NULL),
/// and must not be used again after this call.
#[no_mangle]
pub unsafe extern "C" fn rk_ffi_destroy(engine: *mut c_void) {
    if engine.is_null() {
        return;
    }
    let mut state = Box::from_raw(engine as *mut EngineState);

    // ── Step 1 & 2: send "quit" then close the channel ───────────────────────
    {
        let mut guard = state.sender.lock().unwrap();
        if let Some(tx) = guard.take() {
            // Send "quit" so the engine breaks its recv() loop promptly.
            let _ = tx.send("quit".to_string());
            // tx is dropped here — closing the channel (backup EOF).
        }
    }

    // ── Step 3: join engine thread ────────────────────────────────────────────
    if let Some(handle) = state.engine_handle.take() {
        eprintln!("[creckless] destroy: joining engine thread…");
        let _ = handle.join();
        eprintln!("[creckless] destroy: engine thread joined");
    }

    // ── Step 4: Box drops here ────────────────────────────────────────────────
    eprintln!("[creckless] destroy: complete");
    // state drops at end of scope — EngineState freed.
}

/// Register a callback for UCI output lines.
///
/// May be called at any time after rk_ffi_create.  The callback fires from the
/// engine thread (or search worker threads); it must be reentrant and must NOT
/// call back into rk_ffi_*.
///
/// # Safety
/// `engine` must be non-NULL and valid.  `context` must remain valid until
/// rk_ffi_destroy is called.
#[no_mangle]
pub unsafe extern "C" fn rk_ffi_set_output_callback(
    engine: *mut c_void,
    callback: RKOutputCallback,
    context: *const c_void,
) {
    if engine.is_null() {
        return;
    }
    let state = &*(engine as *mut EngineState);
    let mut cb_guard = state.shared_cb.lock().unwrap();
    cb_guard.callback = callback;
    cb_guard.callback_context = context;
}

/// Send a UCI command to the engine.
///
/// Appends a newline is NOT needed — the engine receives whole strings.
/// Thread-safe (mpsc Sender is Send).
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
    let cmd_str = match CStr::from_ptr(command).to_str() {
        Ok(s) => s.to_owned(),
        Err(_) => return,
    };

    let guard = state.sender.lock().unwrap();
    if let Some(tx) = &*guard {
        let _ = tx.send(cmd_str);
    }
    // If sender is None (destroy in progress), silently discard.
}
