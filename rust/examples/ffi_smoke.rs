// examples/ffi_smoke.rs
//
// C-ABI smoke check for the Reckless FFI bridge (#97, P2 gate).
//
// Exercises the REAL rk_ffi_* C ABI (not reckless::run directly), verifying the
// full pipeline: create -> set_callback -> send "uci"/"isready"/"go" -> collect
// output via the callback -> destroy.  Prints "── PASS" and exits 0 on success;
// prints a "FAIL:" line and exits 1 otherwise.
//
//   cargo run --example ffi_smoke
//
// WHY AN EXAMPLE, NOT A `#[test]`:  the FFI hijacks process-global fd 1 (stdout)
// for the engine's lifetime — Rust's `println!` has no per-object redirect like
// C++'s std::cout.  `cargo test`'s default stdout-capture harness ALSO grabs
// fd 1, and the two collide: under `cargo test` (without --nocapture) the
// engine's lines never reach the callback and the check fails.  As an example
// there is no capture harness, so it runs deterministically.  (Same reason the
// P1 spike is an example.)  On device this fd-1 hijack is low-impact because
// apps log via os_log / logcat, not fd 1.

use creckless::ffi::{
    rk_ffi_create, rk_ffi_destroy, rk_ffi_send_command, rk_ffi_set_output_callback,
};
use libc::c_void;
use std::ffi::{CStr, CString, c_char};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

struct Collector {
    lines: Mutex<Vec<String>>,
}
impl Collector {
    fn new() -> Self {
        Collector { lines: Mutex::new(Vec::new()) }
    }
    fn get_lines(&self) -> Vec<String> {
        self.lines.lock().unwrap().clone()
    }
}

/// # Safety
/// `context` is a `*const Collector`; `line` is a valid NUL-terminated C string.
unsafe extern "C" fn collect_line(line: *const c_char, context: *const c_void) {
    let s = unsafe { CStr::from_ptr(line) }.to_string_lossy().to_string();
    let collector = unsafe { &*(context as *const Collector) };
    collector.lines.lock().unwrap().push(s);
}

fn wait_for<F: Fn(&[String]) -> bool>(collector: &Collector, pred: F, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        if pred(&collector.get_lines()) {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn fail(msg: &str, lines: &[String]) -> ! {
    eprintln!("FAIL: {msg}");
    eprintln!("  lines received: {lines:?}");
    std::process::exit(1);
}

fn main() {
    // Locate the NNUE net relative to the crate manifest directory.
    // The net is no longer baked into the binary — it must be present on disk.
    let net_path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/networks/v54-5478683c.nnue"
    );
    if !std::path::Path::new(net_path).exists() {
        eprintln!(
            "FAIL: NNUE net not found at {net_path}\n\
             Download it with:\n  \
             curl -L -o {net_path} \
             https://github.com/codedeliveryservice/RecklessNetworks/releases/download/networks/v54-5478683c.nnue"
        );
        std::process::exit(1);
    }

    let collector = Arc::new(Collector::new());

    let net_cstr = std::ffi::CString::new(net_path).unwrap();
    let engine = unsafe { rk_ffi_create(net_cstr.as_ptr()) };
    if engine.is_null() {
        fail("rk_ffi_create returned NULL — engine failed to start", &[]);
    }

    let ctx_ptr: *const c_void = Arc::as_ptr(&collector) as *const c_void;
    unsafe { rk_ffi_set_output_callback(engine, Some(collect_line), ctx_ptr) };

    // uci -> uciok + id name Reckless
    let uci_cmd = CString::new("uci").unwrap();
    unsafe { rk_ffi_send_command(engine, uci_cmd.as_ptr()) };
    if !wait_for(&collector, |l| l.iter().any(|x| x == "uciok"), Duration::from_secs(10)) {
        fail("timed out waiting for 'uciok'", &collector.get_lines());
    }
    let after_uci = collector.get_lines();
    eprintln!("── Lines after 'uci' ({} total) ──", after_uci.len());
    for l in &after_uci {
        eprintln!("  {l}");
    }
    if !after_uci.iter().any(|l| l.starts_with("id name Reckless")) {
        fail("'id name Reckless' not found", &after_uci);
    }

    // isready -> readyok
    let isready_cmd = CString::new("isready").unwrap();
    unsafe { rk_ffi_send_command(engine, isready_cmd.as_ptr()) };
    if !wait_for(&collector, |l| l.iter().any(|x| x == "readyok"), Duration::from_secs(5)) {
        fail("timed out waiting for 'readyok'", &collector.get_lines());
    }
    eprintln!("✓ readyok received");

    // go depth 1 -> bestmove
    let go_cmd = CString::new("go depth 1").unwrap();
    unsafe { rk_ffi_send_command(engine, go_cmd.as_ptr()) };
    if !wait_for(&collector, |l| l.iter().any(|x| x.starts_with("bestmove")), Duration::from_secs(30)) {
        fail("timed out waiting for 'bestmove'", &collector.get_lines());
    }
    let bestmove_line = collector.get_lines().into_iter().find(|l| l.starts_with("bestmove")).unwrap();
    eprintln!("✓ bestmove received: {bestmove_line}");

    // destroy — must return promptly, no hang
    let t0 = Instant::now();
    unsafe { rk_ffi_destroy(engine) };
    let dt = t0.elapsed();
    eprintln!("── rk_ffi_destroy returned in {dt:?}");
    if dt >= Duration::from_secs(10) {
        eprintln!("FAIL: rk_ffi_destroy hung for {dt:?}");
        std::process::exit(1);
    }

    eprintln!("── PASS: all assertions met ──");
}
