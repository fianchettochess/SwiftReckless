// examples/terminal_guard.rs
//
// Verifies the terminal-position engine guard: searching a checkmate/stalemate
// position (zero legal moves) must return `bestmove (none)` promptly instead of
// SIGABRTing on `search::start`'s empty `root_moves[0]` index.
//
// Regression for the Android/iOS launch crash: restoring an autosaved game that
// ended in checkmate left the eval-bar/second-opinion Reckless search pointed at
// a terminal FEN, and the un-guarded engine aborted on the reckless-uci thread.
//
//   cargo run --example terminal_guard
//
// PASS criteria:
//   1. `go` on a checkmate FEN yields a `bestmove` line (specifically
//      `bestmove (none)`) within a few seconds — no crash, no hang.
//   2. A subsequent normal `startpos` search still returns a real bestmove,
//      proving the guard left the engine usable (not wedged).

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
/// `context` is a `*const Collector`; a non-null `line` is a valid
/// NUL-terminated C string. A null `line` is the documented EOF sentinel.
unsafe extern "C" fn collect_line(line: *const c_char, context: *const c_void) {
    if line.is_null() {
        return;
    }
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
    println!("FAIL: {msg}");
    println!("  lines received: {lines:?}");
    std::process::exit(1);
}

fn send(engine: *mut c_void, cmd: &str) {
    let c = CString::new(cmd).unwrap();
    unsafe { rk_ffi_send_command(engine, c.as_ptr()) };
}

fn main() {
    let net_path = concat!(env!("CARGO_MANIFEST_DIR"), "/networks/v54-5478683c.nnue");
    if !std::path::Path::new(net_path).exists() {
        println!("FAIL: NNUE net not found at {net_path}");
        std::process::exit(1);
    }

    let collector = Arc::new(Collector::new());
    let net_cstr = CString::new(net_path).unwrap();
    let engine = unsafe { rk_ffi_create(net_cstr.as_ptr()) };
    if engine.is_null() {
        fail("rk_ffi_create returned NULL — engine failed to start", &[]);
    }
    let ctx_ptr: *const c_void = Arc::as_ptr(&collector) as *const c_void;
    unsafe { rk_ffi_set_output_callback(engine, Some(collect_line), ctx_ptr) };

    send(engine, "uci");
    if !wait_for(&collector, |l| l.iter().any(|x| x == "uciok"), Duration::from_secs(10)) {
        fail("timed out waiting for 'uciok'", &collector.get_lines());
    }
    send(engine, "isready");
    if !wait_for(&collector, |l| l.iter().any(|x| x == "readyok"), Duration::from_secs(5)) {
        fail("timed out waiting for 'readyok'", &collector.get_lines());
    }
    println!("engine up (uciok + readyok)");

    // ── 1. TERMINAL POSITION: Fool's Mate final position, white to move,
    //        checkmated → zero legal moves. Un-guarded engine SIGABRTs here.
    let mate_fen = "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3";
    println!("→ searching TERMINAL (checkmate) position: {mate_fen}");
    send(engine, &format!("position fen {mate_fen}"));
    send(engine, "go depth 8");
    if !wait_for(&collector, |l| l.iter().any(|x| x.starts_with("bestmove")), Duration::from_secs(10)) {
        fail("TERMINAL search produced no bestmove (engine crashed or hung on empty root_moves)", &collector.get_lines());
    }
    let mate_best = collector.get_lines().into_iter().rev().find(|l| l.starts_with("bestmove")).unwrap();
    println!("  terminal bestmove: {mate_best}");
    if !(mate_best.contains("(none)") || mate_best.contains("0000")) {
        fail("TERMINAL search returned a real move for a checkmate position (expected 'bestmove (none)')", &collector.get_lines());
    }
    println!("  ✓ guard fired: null bestmove, no crash");

    // ── 2. NORMAL POSITION after the terminal one: engine must still work.
    println!("→ searching NORMAL startpos to prove the engine is not wedged");
    send(engine, "position startpos");
    send(engine, "go depth 8");
    let before = collector.get_lines().len();
    if !wait_for(&collector, |l| l.iter().skip(before).any(|x| x.starts_with("bestmove")), Duration::from_secs(30)) {
        fail("NORMAL search after a terminal one produced no bestmove (engine wedged)", &collector.get_lines());
    }
    let norm_best = collector.get_lines().into_iter().rev().find(|l| l.starts_with("bestmove")).unwrap();
    println!("  startpos bestmove: {norm_best}");
    if norm_best.contains("(none)") {
        fail("NORMAL startpos returned null bestmove — guard is over-firing", &collector.get_lines());
    }
    println!("  ✓ engine still functional after a terminal search");

    unsafe { rk_ffi_destroy(engine) };
    println!("── PASS: terminal-position guard verified ──");
}
