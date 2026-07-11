// tests/ffi_smoke.rs — automated C-ABI regression test for the Reckless FFI.
//
// Exercises the REAL rk_ffi_* C ABI end-to-end: create -> set_callback ->
// uci/isready/go -> collect output via the callback -> destroy. This is a proper
// `#[test]` (runs under `cargo test`) now that the per-instance-I/O rework removed
// the fd-1 hijack — previously it had to be an example because the fd redirect
// collided with cargo test's stdout-capture harness.
//
// Net guard: the NNUE net is gitignored (~60 MB). If it isn't staged at
// rust/networks/, the test prints a note and passes (skips) so a fresh checkout /
// CI without the net stays green.
//
// This crate has exactly ONE engine test, so cargo test's default parallelism
// cannot introduce an unrelated engine. The test itself verifies that overlap
// and the pinned fork's currently-unsafe restart both fail promptly.

use creckless::ffi::{
    rk_ffi_create, rk_ffi_destroy, rk_ffi_send_command, rk_ffi_set_output_callback,
};
use libc::c_void;
use std::ffi::{c_char, CStr, CString};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const NET_PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/networks/v54-5478683c.nnue");

struct Collector {
    lines: Mutex<Vec<String>>,
}

unsafe extern "C" fn collect_line(line: *const c_char, context: *const c_void) {
    let s = unsafe { CStr::from_ptr(line) }
        .to_string_lossy()
        .to_string();
    let collector = unsafe { &*(context as *const Collector) };
    collector.lines.lock().unwrap().push(s);
}

fn wait_for<F: Fn(&[String]) -> bool>(c: &Collector, pred: F, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        if pred(&c.lines.lock().unwrap()) {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn ffi_uci_isready_bestmove() {
    if !Path::new(NET_PATH).exists() {
        eprintln!("[ffi_smoke] SKIP — NNUE net not staged at {NET_PATH}");
        return; // treated as a pass; the net is gitignored (see rust/networks/)
    }

    let collector = Arc::new(Collector {
        lines: Mutex::new(Vec::new()),
    });

    let net = CString::new(NET_PATH).unwrap();
    let engine = unsafe { rk_ffi_create(net.as_ptr()) };
    assert!(
        !engine.is_null(),
        "rk_ffi_create returned NULL (engine failed to start)"
    );

    let ctx = Arc::as_ptr(&collector) as *const c_void;
    unsafe { rk_ffi_set_output_callback(engine, Some(collect_line), ctx) };

    let uci = CString::new("uci").unwrap();
    unsafe { rk_ffi_send_command(engine, uci.as_ptr()) };
    assert!(
        wait_for(
            &collector,
            |l| l.iter().any(|x| x == "uciok"),
            Duration::from_secs(10)
        ),
        "timed out waiting for uciok; got {:?}",
        collector.lines.lock().unwrap()
    );
    assert!(
        collector
            .lines
            .lock()
            .unwrap()
            .iter()
            .any(|l| l.starts_with("id name Reckless")),
        "missing 'id name Reckless'"
    );

    let isready = CString::new("isready").unwrap();
    unsafe { rk_ffi_send_command(engine, isready.as_ptr()) };
    assert!(
        wait_for(
            &collector,
            |l| l.iter().any(|x| x == "readyok"),
            Duration::from_secs(5)
        ),
        "timed out waiting for readyok"
    );

    let go = CString::new("go depth 1").unwrap();
    unsafe { rk_ffi_send_command(engine, go.as_ptr()) };
    assert!(
        wait_for(
            &collector,
            |l| l.iter().any(|x| x.starts_with("bestmove")),
            Duration::from_secs(30)
        ),
        "timed out waiting for bestmove"
    );

    // Overlap is rejected immediately rather than entering the process-global
    // engine. The pinned fork also has a non-idempotent lookup initializer, so
    // a restart after destroy is rejected until that fork adds a Once guard.
    let second_net = CString::new(NET_PATH).unwrap();
    let reject_started = Instant::now();
    let overlapping = unsafe { rk_ffi_create(second_net.as_ptr()) };
    assert!(overlapping.is_null(), "overlapping create was not rejected");
    assert!(
        reject_started.elapsed() < Duration::from_secs(1),
        "overlapping create did not fail promptly"
    );

    let t0 = Instant::now();
    unsafe { rk_ffi_destroy(engine) };
    assert!(
        t0.elapsed() < Duration::from_secs(10),
        "rk_ffi_destroy hung"
    );

    let restart_started = Instant::now();
    let restart = unsafe { rk_ffi_create(second_net.as_ptr()) };
    assert!(
        restart.is_null(),
        "unsafe second engine lifetime was not rejected"
    );
    assert!(restart_started.elapsed() < Duration::from_secs(1));
}
