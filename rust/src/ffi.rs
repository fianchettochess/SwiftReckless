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
//      safe. The pinned fork makes initialization restart-safe, so a clean
//      destroy releases this lease for a later sequential lifetime.
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
use std::io;
use std::panic::{catch_unwind, AssertUnwindSafe};
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
    /// True while an engine lifetime holds the process slot. Overlapping
    /// engines are never safe (the NNUE net and lookup tables are
    /// process-global). A CLEAN destroy releases the slot and a new engine
    /// may start — the pinned fork (swiftreckless-v0.9.1+) Once-guards its
    /// table initializers and supports net unload, so repeated lifetimes
    /// are safe. The stuck-thread teardown path in rk_ffi_create
    /// `mem::forget`s its lease instead, leaving `live` set forever: a
    /// detached engine thread may still be running, so the process slot is
    /// deliberately poisoned for the remainder of the process.
    live: bool,
}

struct LifecycleGate {
    state: Mutex<LifecycleState>,
}

impl LifecycleGate {
    fn try_acquire(&'static self) -> Option<LifecycleLease> {
        let mut state = self.state.lock().unwrap();
        if state.live {
            return None;
        }
        state.live = true;
        Some(LifecycleLease { gate: self })
    }

    fn release(&self) {
        self.state.lock().unwrap().live = false;
    }
}

fn lifecycle_gate() -> &'static LifecycleGate {
    static GATE: OnceLock<LifecycleGate> = OnceLock::new();
    GATE.get_or_init(|| LifecycleGate {
        state: Mutex::new(LifecycleState { live: false }),
    })
}

struct LifecycleLease {
    gate: &'static LifecycleGate,
}

impl Drop for LifecycleLease {
    fn drop(&mut self) {
        self.gate.release();
    }
}

// ── Failure containment and command validation ──────────────────────────────

const MAX_HASH_MIB: usize = 262_144;
const MIN_THREAD_OPTION: usize = 1;
const MIN_RECKLESS_THREAD_LIMIT: usize = 512;
const MAX_MOVE_OVERHEAD_MS: u64 = 2_000;
const MAX_MULTI_PV: usize = 256;

/// Mirrors the pinned engine's advertised `Threads` maximum without reaching
/// into its private `threadpool` module.
fn maximum_reckless_threads() -> usize {
    thread::available_parallelism()
        .map(|count| count.get().saturating_mul(4).max(MIN_RECKLESS_THREAD_LIMIT))
        .unwrap_or(MIN_RECKLESS_THREAD_LIMIT)
}

fn parses_inclusive<T>(value: &str, minimum: T, maximum: T) -> bool
where
    T: std::str::FromStr + PartialOrd,
{
    value
        .parse::<T>()
        .map(|parsed| parsed >= minimum && parsed <= maximum)
        .unwrap_or(false)
}

/// The pinned Reckless parser still uses `parse().unwrap()` for these exact
/// command shapes. `rk_ffi_send_command` is a public raw-string boundary, so a
/// malformed value must be rejected before it can reach a release engine.
/// Other `setoption` shapes fall through to the engine's non-panicking
/// "unknown option" handling. Unexpected engine defects are separately
/// contained at the engine-thread boundary below.
fn command_avoids_known_parser_abort(command: &str) -> bool {
    let tokens = command.split_whitespace().collect::<Vec<_>>();
    match tokens.as_slice() {
        ["setoption", "name", "Hash", "value", value] => {
            parses_inclusive(value, 1usize, MAX_HASH_MIB)
        }
        ["setoption", "name", "Threads", "value", value] => {
            parses_inclusive(value, MIN_THREAD_OPTION, maximum_reckless_threads())
        }
        ["setoption", "name", "MoveOverhead", "value", value] => {
            parses_inclusive(value, 0u64, MAX_MOVE_OVERHEAD_MS)
        }
        ["setoption", "name", "MultiPV", "value", value] => {
            parses_inclusive(value, 1usize, MAX_MULTI_PV)
        }
        ["setoption", "name", "UCI_Chess960" | "Minimal", "value", value] => {
            matches!(*value, "true" | "false")
        }
        // The engine's perft implementation subtracts one from depth before
        // recurring. Reject zero as well as values that fail usize parsing.
        ["perft", depth] => parses_inclusive(depth, 1usize, usize::MAX),
        _ => true,
    }
}

fn spawn_engine_thread_with<F, S>(thread_main: F, spawn: S) -> io::Result<thread::JoinHandle<()>>
where
    F: FnOnce() + Send + 'static,
    S: FnOnce(thread::Builder, F) -> io::Result<thread::JoinHandle<()>>,
{
    let builder = thread::Builder::new()
        .name("reckless-uci".into())
        .stack_size(8 * 1024 * 1024); // 8 MB — search is stack-heavy
    spawn(builder, thread_main)
}

fn spawn_engine_thread<F>(thread_main: F) -> io::Result<thread::JoinHandle<()>>
where
    F: FnOnce() + Send + 'static,
{
    spawn_engine_thread_with(thread_main, |builder, main| builder.spawn(main))
}

/// Contain panics raised by the pinned engine (including worker-thread
/// creation failures propagated by its joins) inside the Rust engine thread.
/// The release profile must remain `panic = "unwind"` for this boundary to be
/// effective.
fn run_engine_contained<F>(engine_main: F) -> bool
where
    F: FnOnce(),
{
    catch_unwind(AssertUnwindSafe(engine_main)).is_ok()
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
    // Reject overlapping engine lifetimes before touching the process-global
    // tables; see LifecycleState. After a clean rk_ffi_destroy the slot is
    // released and a fresh lifetime may start (fork swiftreckless-v0.9.1+).
    let lifecycle_lease = match lifecycle_gate().try_acquire() {
        Some(lease) => lease,
        None => {
            eprintln!(
                "[creckless] rk_ffi_create: engine lifetime unavailable; \
                 an engine is live (or a failed lifetime poisoned the process)"
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
    // A second handle used only to emit an end-of-output signal when the engine
    // thread exits (see the thread body below).
    let shared_cb_exit = Arc::clone(&shared_cb);
    // `rk_ffi_create` must not return while run_io is still constructing its
    // worker pool. An immediate destroy in that window exposed a Reckless
    // startup/teardown race that could hang the join. A private isready probe
    // gives us an unambiguous "message loop is live" handshake.
    let (startup_ready_tx, startup_ready_rx) = std::sync::mpsc::channel::<()>();

    // ── 3. Spawn engine thread ────────────────────────────────────────────────
    // reckless::run_io blocks until "quit" or channel close.
    // The output closure captures shared_cb_engine and fires for every UCI line.
    let engine_handle = match spawn_engine_thread(move || {
        let completed_without_panic = run_engine_contained(|| {
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
        });
        // run_io normally clears this itself, but an unwind skips its trailing
        // cleanup. Clear the process-global sink before the Swift callback
        // context can be released by shutdown.
        reckless::set_output_sink(None);
        if !completed_without_panic {
            eprintln!("[creckless] reckless engine panicked; terminating this engine instance");
        }
        // Signal end-of-output to the host: a NULL line pointer tells the Swift
        // output callback the engine thread has exited — a normal quit OR a
        // contained panic — so a consumer awaiting the output stream gets EOF
        // instead of hanging forever. The C callback lives in `shared_cb`
        // (separate from the reckless sink cleared just above).
        {
            let cb_guard = shared_cb_exit.lock().unwrap();
            if let Some(cb) = cb_guard.callback {
                let ctx = cb_guard.callback_context;
                drop(cb_guard);
                // SAFETY: a NULL line is the agreed engine-exit sentinel; ctx
                // outlives the engine per the Swift caller's contract.
                unsafe { cb(std::ptr::null(), ctx) };
            }
        }
    }) {
        Ok(handle) => handle,
        Err(error) => {
            eprintln!("[creckless] rk_ffi_create: failed to spawn engine thread: {error}");
            // No engine thread exists; free the just-loaded net so the
            // released lifetime leaves no residue.
            reckless::nnue::unload_network();
            return std::ptr::null_mut();
        }
    };

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
            // Thread joined: no engine-owned thread can touch the net.
            reckless::nnue::unload_network();
        } else {
            // Rust has no safe way to kill a stuck thread. Detach it so the C
            // caller receives NULL after the bounded timeout, and permanently
            // poison the process lifecycle slot (the forgotten lease keeps
            // `live` set) so no later engine can race the still-running
            // thread. The net is deliberately NOT unloaded here — the
            // detached thread may still read it. Closing tx above lets a
            // merely slow (not stuck) loop observe EOF and exit eventually.
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

    // ── Step 3b: free the ~60 MB NNUE net ────────────────────────────────────
    // Safe exactly here: the engine thread is joined and its worker pool
    // joins its threads on drop (fork swiftreckless-v0.9.1), so no
    // engine-owned thread can still read the net. This returns the host
    // process to its no-engine memory baseline; the next rk_ffi_create
    // reloads the net from disk.
    reckless::nnue::unload_network();

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
    if !command_avoids_known_parser_abort(&cmd_str) {
        eprintln!("[creckless] rejected malformed or out-of-range UCI command");
        return;
    }

    let guard = state.sender.lock().unwrap();
    if let Some(tx) = &*guard {
        let _ = tx.send(cmd_str);
    }
    // If sender is None (destroy in progress), silently discard.
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    #[test]
    fn rejects_values_that_can_panic_the_pinned_uci_parser() {
        assert!(command_avoids_known_parser_abort(
            "setoption name Hash value 1"
        ));
        assert!(command_avoids_known_parser_abort(
            "setoption name Hash value 262144"
        ));
        assert!(!command_avoids_known_parser_abort(
            "setoption name Hash value nope"
        ));
        assert!(!command_avoids_known_parser_abort(
            "setoption name Hash value 0"
        ));
        assert!(!command_avoids_known_parser_abort(
            "setoption name Hash value 262145"
        ));

        assert!(command_avoids_known_parser_abort(
            "setoption name Threads value 1"
        ));
        assert!(!command_avoids_known_parser_abort(
            "setoption name Threads value nope"
        ));
        assert!(!command_avoids_known_parser_abort(
            "setoption name Threads value 0"
        ));

        assert!(command_avoids_known_parser_abort(
            "setoption name MoveOverhead value 0"
        ));
        assert!(command_avoids_known_parser_abort(
            "setoption name MoveOverhead value 2000"
        ));
        assert!(!command_avoids_known_parser_abort(
            "setoption name MoveOverhead value -1"
        ));
        assert!(!command_avoids_known_parser_abort(
            "setoption name MoveOverhead value 2001"
        ));

        assert!(command_avoids_known_parser_abort(
            "setoption name MultiPV value 1"
        ));
        assert!(command_avoids_known_parser_abort(
            "setoption name MultiPV value 256"
        ));
        assert!(!command_avoids_known_parser_abort(
            "setoption name MultiPV value 0"
        ));
        assert!(!command_avoids_known_parser_abort(
            "setoption name MultiPV value 257"
        ));

        assert!(command_avoids_known_parser_abort("perft 1"));
        assert!(!command_avoids_known_parser_abort("perft 0"));
        assert!(!command_avoids_known_parser_abort("perft nope"));
        assert!(command_avoids_known_parser_abort("position startpos"));
    }

    #[test]
    fn thread_spawn_failure_is_returned_without_running_engine_main() {
        let ran = Arc::new(AtomicBool::new(false));
        let ran_on_thread = Arc::clone(&ran);
        let result = spawn_engine_thread_with(
            move || ran_on_thread.store(true, Ordering::SeqCst),
            |_builder, _main| Err(io::Error::from(io::ErrorKind::WouldBlock)),
        );

        assert!(result.is_err());
        assert!(!ran.load(Ordering::SeqCst));
    }

    #[test]
    fn engine_panics_are_contained_on_the_rust_thread() {
        assert!(!run_engine_contained(|| panic!("synthetic engine panic")));
    }
}
