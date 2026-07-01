// creckless/src/ffi.rs
//
// C FFI surface for the SwiftReckless bridge.
//
// ── Threading model ──────────────────────────────────────────────────────────
//
// PROCESS-GLOBAL FD REDIRECT — ONE ENGINE AT A TIME
// Both Reckless (this) and Stockfish (CStockfish) hijack the PROCESS-WIDE file
// descriptors 0 (stdin) and 1 (stdout).  Only one engine may be live at any
// moment.  The app must call rk_ffi_destroy (and the Stockfish equivalent)
// before creating a new engine of the other type.  This matches CStockfish's
// own constraint.
//
// rk_ffi_create:
//   1. dup the real fd 0 and fd 1 aside so we can restore them on destroy.
//   2. Create two pipes: one for stdin (write→engine), one for stdout (engine→reader).
//   3. dup2 the stdin-pipe READ end onto fd 0 and the stdout-pipe WRITE end onto fd 1.
//   4. Spawn the engine thread: reckless::run(VecDeque::new()) — reads fd 0, writes fd 1.
//   5. Spawn a reader thread: reads lines from stdout-pipe READ end, calls the callback.
//
// rk_ffi_send_command:
//   Write "{cmd}\n" to the stdin-pipe WRITE fd.  Thread-safe (only one writer,
//   but we hold the fd behind a Mutex to prevent concurrent partial writes).
//
// rk_ffi_set_output_callback:
//   Store the callback+context into the Arc<Mutex<SharedCallback>> that the reader
//   thread also holds.  Lines that arrive before a callback is set are silently
//   dropped — this is safe because the app sets the callback before sending any
//   command that produces output (same contract as CStockfish).
//
// rk_ffi_destroy — SHUTDOWN ORDER (deadlock-free reasoning):
//   A. Write "quit\n" to the stdin pipe.  Reckless's listener thread reads it,
//      sets Status::STOPPED, sends "quit" to message_loop, then exits its own
//      loop.  message_loop receives "quit", drops the ThreadPool, and returns.
//      → engine thread exits.
//   B. Close the stdin-pipe WRITE fd (the one creckless holds).  This is EOF
//      backup: if the "quit" was already processed this is a no-op from the
//      engine's perspective; if not, the listener sees EOF.  We close it NOW
//      (before joining engine thread) so the engine can't get stuck waiting for
//      more stdin input.
//   C. Join the engine thread.  After join, fd 1 (the dup2'd stdout-pipe write
//      alias) is the ONLY remaining reference the engine had to the stdout-pipe
//      write end — it's closed because the engine thread (which called println!
//      to fd 1) has exited.  BUT fd 1 is still pointing at stdout-pipe write end
//      at the OS level until we dup2 restore.
//   D. Restore fd 0 and fd 1 from the saved duplicates.  This replaces fd 1 with
//      the real terminal/saved stdout, and atomically closes the stdout-pipe write
//      end alias (dup2 closes the target before replacing it).  The reader thread
//      will now see EOF on its read end of stdout-pipe.
//   E. Join the reader thread.
//
//   WHY THIS ORDER IS DEADLOCK-FREE:
//   - The reader thread blocks on read() from stdout-pipe read end.
//   - The reader thread does NOT hold any lock that the engine thread needs.
//   - We join the engine thread BEFORE closing stdout-pipe write end (step D),
//     so the engine can't block writing to a closed pipe.  Actually: the engine
//     thread exits after "quit", so it stops writing before we restore.
//   - We restore fd 1 (step D) AFTER the engine thread joins (step C), so the
//     engine can flush final output before EOF is signalled to the reader.
//   - Joining the reader thread last (step E) ensures all output is delivered.
//
// CALLBACK ORDERING:
//   The app calls rk_ffi_set_output_callback AFTER rk_ffi_create (matching
//   CStockfish's lifecycle).  Lines that arrive before the callback is set are
//   dropped — acceptable because the app must set the callback before sending
//   any command that produces output.  We use Arc<Mutex<SharedCallback>> shared
//   between the main state and the reader thread.

use libc::{c_char, c_int, c_void};
use std::collections::VecDeque;
use std::ffi::{CStr, CString};
use std::os::fd::FromRawFd;
use std::sync::{Arc, Mutex};
use std::thread;

// ── Types ─────────────────────────────────────────────────────────────────────

/// C-visible callback type (matches RecklessBridge.h).
pub type RKOutputCallback =
    Option<unsafe extern "C" fn(line: *const c_char, context: *const c_void)>;

/// Shared between the main EngineState and the reader thread.
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
    /// Write end of the stdin pipe.  We write commands here; the engine reads fd 0.
    /// Wrapped in Mutex to allow thread-safe writes (only one writer, but Mutex
    /// ensures no partial-write races if multiple threads ever call send_command).
    stdin_write_fd: Mutex<c_int>,
    /// Saved original fd 0 (restored on destroy).
    saved_stdin_fd: c_int,
    /// Saved original fd 1 (restored on destroy).
    saved_stdout_fd: c_int,
    /// Engine thread handle.
    engine_handle: Option<thread::JoinHandle<()>>,
    /// Reader thread handle.
    reader_handle: Option<thread::JoinHandle<()>>,
    /// Shared callback state (also held by reader thread).
    shared_cb: Arc<Mutex<SharedCallback>>,
}

// SAFETY: See SharedCallback above.
unsafe impl Send for EngineState {}
unsafe impl Sync for EngineState {}

// ── FFI functions (rk_ffi_* prefix) ──────────────────────────────────────────

/// Create and start a Reckless engine instance.
///
/// `network_path` must be a valid NUL-terminated C string pointing to the
/// Reckless NNUE net file (e.g. "v54-5478683c.nnue").  NULL is no longer
/// accepted — the net is required at runtime (no longer baked into the binary).
///
/// Returns an opaque non-NULL pointer on success, NULL on failure.
/// The returned pointer must be passed to rk_ffi_destroy exactly once.
///
/// # Safety
/// `network_path` must be a valid NUL-terminated C string or NULL (NULL → error).
#[no_mangle]
pub unsafe extern "C" fn rk_ffi_create(network_path: *const c_char) -> *mut c_void {
    // ── 0. Load NNUE net from the supplied path ───────────────────────────────
    if network_path.is_null() {
        eprintln!("[creckless] rk_ffi_create: network_path is NULL — net is required (no longer compile-time embedded)");
        return std::ptr::null_mut();
    }
    let net_path_str = match CStr::from_ptr(network_path).to_str() {
        Ok(s) => s.to_owned(),
        Err(_) => {
            eprintln!("[creckless] rk_ffi_create: network_path is not valid UTF-8");
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
        Ok(()) => eprintln!("[creckless] rk_ffi_create: NNUE net loaded ({} bytes)", net_bytes.len()),
        Err(e) => {
            // "already loaded" is non-fatal (e.g. second engine creation in same process).
            if e.contains("already loaded") {
                eprintln!("[creckless] rk_ffi_create: NNUE net already loaded, continuing");
            } else {
                eprintln!("[creckless] rk_ffi_create: load_network failed: {e}");
                return std::ptr::null_mut();
            }
        }
    }

    // ── 1. Save real fd 0 and fd 1 ───────────────────────────────────────────
    let saved_stdin_fd = libc::dup(libc::STDIN_FILENO);
    if saved_stdin_fd < 0 {
        eprintln!("[creckless] dup(stdin) failed: {}", std::io::Error::last_os_error());
        return std::ptr::null_mut();
    }
    let saved_stdout_fd = libc::dup(libc::STDOUT_FILENO);
    if saved_stdout_fd < 0 {
        eprintln!("[creckless] dup(stdout) failed: {}", std::io::Error::last_os_error());
        libc::close(saved_stdin_fd);
        return std::ptr::null_mut();
    }

    // ── 2. Create stdin pipe [read_end → fd 0, write_end held by us] ─────────
    let mut stdin_pipe: [c_int; 2] = [-1; 2];
    if libc::pipe(stdin_pipe.as_mut_ptr()) != 0 {
        eprintln!("[creckless] pipe(stdin) failed: {}", std::io::Error::last_os_error());
        libc::close(saved_stdin_fd);
        libc::close(saved_stdout_fd);
        return std::ptr::null_mut();
    }
    let (stdin_read_fd, stdin_write_fd) = (stdin_pipe[0], stdin_pipe[1]);

    // ── 3. Create stdout pipe [write_end → fd 1, read_end held by reader] ────
    let mut stdout_pipe: [c_int; 2] = [-1; 2];
    if libc::pipe(stdout_pipe.as_mut_ptr()) != 0 {
        eprintln!("[creckless] pipe(stdout) failed: {}", std::io::Error::last_os_error());
        libc::close(stdin_read_fd);
        libc::close(stdin_write_fd);
        libc::close(saved_stdin_fd);
        libc::close(saved_stdout_fd);
        return std::ptr::null_mut();
    }
    let (stdout_read_fd, stdout_write_fd) = (stdout_pipe[0], stdout_pipe[1]);

    // ── 4. dup2 into fd 0 and fd 1 ───────────────────────────────────────────
    // dup2(stdin_read_fd, STDIN_FILENO): fd 0 now reads from our stdin pipe.
    if libc::dup2(stdin_read_fd, libc::STDIN_FILENO) != libc::STDIN_FILENO {
        eprintln!("[creckless] dup2(stdin_read) failed: {}", std::io::Error::last_os_error());
        libc::close(stdin_read_fd);
        libc::close(stdin_write_fd);
        libc::close(stdout_read_fd);
        libc::close(stdout_write_fd);
        libc::close(saved_stdin_fd);
        libc::close(saved_stdout_fd);
        return std::ptr::null_mut();
    }
    // fd 0 is now the alias; close the extra copy of the read end.
    libc::close(stdin_read_fd);

    // dup2(stdout_write_fd, STDOUT_FILENO): fd 1 now writes into our stdout pipe.
    if libc::dup2(stdout_write_fd, libc::STDOUT_FILENO) != libc::STDOUT_FILENO {
        eprintln!("[creckless] dup2(stdout_write) failed: {}", std::io::Error::last_os_error());
        // Restore stdin before bailing.
        libc::dup2(saved_stdin_fd, libc::STDIN_FILENO);
        libc::close(stdout_read_fd);
        libc::close(stdout_write_fd);
        libc::close(saved_stdin_fd);
        libc::close(saved_stdout_fd);
        return std::ptr::null_mut();
    }
    // fd 1 is now the alias; close the extra copy of the write end.
    libc::close(stdout_write_fd);

    // ── 5. Shared callback state ──────────────────────────────────────────────
    let shared_cb = Arc::new(Mutex::new(SharedCallback {
        callback: None,
        callback_context: std::ptr::null(),
    }));
    let shared_cb_reader = Arc::clone(&shared_cb);

    // ── 6. Spawn reader thread ────────────────────────────────────────────────
    // The reader owns stdout_read_fd.  It reads lines and fires the callback.
    let reader_handle = thread::Builder::new()
        .name("reckless-reader".into())
        .spawn(move || {
            // SAFETY: we own stdout_read_fd; no one else has this fd now.
            let file = unsafe { std::fs::File::from_raw_fd(stdout_read_fd) };
            let reader = std::io::BufReader::new(file);
            use std::io::BufRead;
            for line in reader.lines() {
                match line {
                    Ok(l) => {
                        // Trim CR that could sneak in on some platforms.
                        let l = l.trim_end_matches('\r');
                        if l.is_empty() {
                            continue;
                        }
                        // Read the current callback each iteration — the app
                        // may set it at any time.  Drop lines when no callback
                        // is registered (acceptable: app sets callback before
                        // any command that produces output).
                        let cb_guard = shared_cb_reader.lock().unwrap();
                        if let Some(cb) = cb_guard.callback {
                            // Build NUL-terminated string; store in a local so
                            // the pointer stays valid across the call.
                            if let Ok(cstr) = CString::new(l) {
                                let ctx = cb_guard.callback_context;
                                // Drop guard before calling into C to avoid
                                // holding the lock during the callback.
                                drop(cb_guard);
                                unsafe { cb(cstr.as_ptr(), ctx) };
                            }
                        }
                        // else: drop the line
                    }
                    Err(_) => break, // EOF or pipe error — reader thread exits
                }
            }
        })
        .expect("[creckless] failed to spawn reckless-reader thread");

    // ── 7. Spawn engine thread ────────────────────────────────────────────────
    // reckless::run() reads fd 0 and writes fd 1 (both now pointed at pipes).
    // We pass an empty VecDeque → Mode::Uci (block on fd 0 / channel).
    let engine_handle = thread::Builder::new()
        .name("reckless-uci".into())
        .stack_size(8 * 1024 * 1024) // 8 MB — search is stack-heavy
        .spawn(move || {
            reckless::run(VecDeque::new());
        })
        .expect("[creckless] failed to spawn reckless-uci thread");

    // ── 8. Box up state and return ────────────────────────────────────────────
    let state = Box::new(EngineState {
        stdin_write_fd: Mutex::new(stdin_write_fd),
        saved_stdin_fd,
        saved_stdout_fd,
        engine_handle: Some(engine_handle),
        reader_handle: Some(reader_handle),
        shared_cb,
    });

    eprintln!("[creckless] rk_ffi_create: engine started (fd0/fd1 redirected to pipes)");
    Box::into_raw(state) as *mut c_void
}

/// Destroy the engine: clean shutdown, no hangs.
///
/// Shutdown order (see module-level comment for full deadlock-free reasoning):
///   1. Write "quit\n" to the stdin pipe.
///   2. Close the stdin pipe write end (EOF signal / backup).
///   3. Join the engine thread.
///   4. Restore fd 0 and fd 1 (this closes the stdout-pipe write alias on fd 1,
///      signalling EOF to the reader thread).
///   5. Join the reader thread.
///   6. Free the Box<EngineState>.
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

    // ── Step 1 & 2: signal quit, then close stdin pipe write end ─────────────
    {
        // Lock the fd to avoid a concurrent rk_ffi_send_command racing with close.
        let mut fd_guard = state.stdin_write_fd.lock().unwrap();
        let fd = *fd_guard;
        if fd >= 0 {
            // Write "quit\n" so the engine's listener thread handles it cleanly.
            let quit = b"quit\n";
            let _ = libc::write(fd, quit.as_ptr() as *const c_void, quit.len());
            // Close the write end: combined with the "quit" this guarantees the
            // engine's stdin listener sees either the command or EOF.
            libc::close(fd);
            *fd_guard = -1; // mark as closed to prevent double-close
        }
    }

    // ── Step 3: join engine thread ────────────────────────────────────────────
    // This blocks until reckless::run() returns.  After "quit", message_loop
    // breaks promptly.  The listener sub-thread inside reckless may linger
    // briefly but message_loop's caller (our engine thread) returns, which is
    // what we join.
    if let Some(handle) = state.engine_handle.take() {
        eprintln!("[creckless] destroy: joining engine thread…");
        let _ = handle.join();
        eprintln!("[creckless] destroy: engine thread joined");
    }

    // ── Step 4: restore fd 0 and fd 1 ────────────────────────────────────────
    // Restoring fd 1 atomically closes the stdout-pipe write alias (dup2 closes
    // the target fd before installing the new one).  After this the reader
    // thread will see EOF on its read end.
    if state.saved_stdout_fd >= 0 {
        libc::dup2(state.saved_stdout_fd, libc::STDOUT_FILENO);
        libc::close(state.saved_stdout_fd);
    }
    if state.saved_stdin_fd >= 0 {
        libc::dup2(state.saved_stdin_fd, libc::STDIN_FILENO);
        libc::close(state.saved_stdin_fd);
    }
    eprintln!("[creckless] destroy: fd 0/1 restored");

    // ── Step 5: join reader thread ────────────────────────────────────────────
    // EOF on the stdout-pipe read end (triggered by step 4) causes the reader's
    // BufRead::lines() iterator to end, so the reader thread exits promptly.
    if let Some(handle) = state.reader_handle.take() {
        eprintln!("[creckless] destroy: joining reader thread…");
        let _ = handle.join();
        eprintln!("[creckless] destroy: reader thread joined");
    }

    // ── Step 6: Box drops here ────────────────────────────────────────────────
    eprintln!("[creckless] destroy: complete");
    // state drops at end of scope — EngineState freed.
}

/// Register a callback for UCI output lines.
///
/// May be called at any time after rk_ffi_create.  The callback fires from the
/// reader thread; it must be reentrant and must NOT call back into rk_ffi_*.
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

/// Send a UCI command to the engine's stdin pipe.
///
/// Appends a newline automatically.  Thread-safe.
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
        Ok(s) => s,
        Err(_) => return,
    };

    let fd_guard = state.stdin_write_fd.lock().unwrap();
    let fd = *fd_guard;
    if fd < 0 {
        return; // already closed (destroy in progress)
    }

    // Write as a single syscall where possible (avoids interleaving if two
    // threads ever call send_command simultaneously, though the Mutex already
    // prevents that).
    let mut line = cmd_str.to_owned();
    line.push('\n');
    let bytes = line.as_bytes();
    let _ = libc::write(fd, bytes.as_ptr() as *const c_void, bytes.len());
}
