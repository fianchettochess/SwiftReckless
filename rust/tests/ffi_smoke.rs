// tests/ffi_smoke.rs — automated C-ABI regression test for the Reckless FFI.
//
// Exercises the REAL rk_ffi_* C ABI end-to-end: create -> set_callback ->
// uci/isready/go -> collect output via the callback -> destroy. This is a proper
// `#[test]` (runs under `cargo test`) now that the per-instance-I/O rework removed
// the fd-1 hijack — previously it had to be an example because the fd redirect
// collided with cargo test's stdout-capture harness.
//
// Net guard: the NNUE net is gitignored (~60 MB). If it isn't staged at
// rust/networks/, the test prints a note and passes (skips) so a fresh checkout
// stays green for a developer who has not downloaded it.
//
// THAT SKIP IS ONLY SAFE WHERE NOBODY IS RELYING ON THIS TEST. It was not: for
// a period, ci.yml's `rust` job — named "SwiftReckless — Rust FFI tests", the
// only pull_request-triggered job touching this crate — never staged the net,
// so it compiled the engine on every run, executed it on none, and reported
// "ok. 1 passed" either way. A test whose name promises FFI coverage passed
// without touching the FFI, and no signal distinguished that from real
// coverage.
//
// So the skip is now OPT-OUT rather than automatic: any job that stages the net
// sets SWIFTRECKLESS_REQUIRE_NET=1, and a missing net there is a FAILURE, not a
// skip. The developer convenience survives; the silent pass in CI cannot. Note
// which failure this catches — not "the download 404'd" (the staging steps use
// `curl -f` plus a checksum and already fail loudly on that), but the quieter
// one: a staging step deleted, renamed, reordered after the test, or left
// pointing at a net filename this file no longer expects.
//
// This crate has exactly ONE engine test, so cargo test's default parallelism
// cannot introduce an unrelated engine. The test itself verifies that overlap
// fails promptly and a clean destroy permits a complete second lifetime.

use creckless::ffi::{
    rk_ffi_create, rk_ffi_destroy, rk_ffi_send_command, rk_ffi_set_output_callback,
};
use libc::c_void;
use std::ffi::{c_char, CStr, CString};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const NET_PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/networks/v54-5478683c.nnue");

/// Set by any CI job that stages the NNUE net, declaring that this job expects
/// the live FFI to actually run. When it is set, an absent net fails the test
/// instead of skipping it.
const REQUIRE_NET_VAR: &str = "SWIFTRECKLESS_REQUIRE_NET";

/// An empty value counts as unset, matching how the release workflow neutralises
/// `SWIFTRECKLESS_FORCE_SOURCE_BUILD: ''` per step — a job can turn the
/// requirement off without having to unset an inherited variable.
fn net_is_required() -> bool {
    std::env::var(REQUIRE_NET_VAR).is_ok_and(|v| !v.is_empty())
}

struct Collector {
    lines: Mutex<Vec<String>>,
}

unsafe extern "C" fn collect_line(line: *const c_char, context: *const c_void) {
    // NULL is the documented engine-exit sentinel (host-side EOF signal),
    // fired from the engine thread during destroy — not a line.
    if line.is_null() {
        return;
    }
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
        assert!(
            !net_is_required(),
            "{REQUIRE_NET_VAR} is set, so this job is supposed to exercise the real \
             rk_ffi_* ABI, but the NNUE net is not staged at {NET_PATH}.\n\
             This test would otherwise have SKIPPED and still reported \"ok. 1 passed\", \
             which is the exact silent pass this variable exists to prevent.\n\
             Either the job's net-staging step is missing/broken, or it stages a \
             different filename than this test expects. Fix the staging — do not \
             unset {REQUIRE_NET_VAR}."
        );
        eprintln!("[ffi_smoke] SKIP — NNUE net not staged at {NET_PATH}");
        eprintln!(
            "[ffi_smoke] the rk_ffi_* ABI was NOT exercised; set {REQUIRE_NET_VAR}=1 \
             to make this a failure"
        );
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
    // engine — overlapping lifetimes are never safe (shared net + tables).
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

    // A clean destroy releases the lifecycle slot and unloads the net
    // (fork swiftreckless-v0.9.1): a SECOND full lifetime must work —
    // create, handshake, search, destroy.
    let restart = unsafe { rk_ffi_create(second_net.as_ptr()) };
    assert!(
        !restart.is_null(),
        "restart after clean destroy was rejected"
    );
    let restart_collector = Arc::new(Collector {
        lines: Mutex::new(Vec::new()),
    });
    let restart_ctx = Arc::as_ptr(&restart_collector) as *const c_void;
    unsafe { rk_ffi_set_output_callback(restart, Some(collect_line), restart_ctx) };
    let isready2 = CString::new("isready").unwrap();
    unsafe { rk_ffi_send_command(restart, isready2.as_ptr()) };
    assert!(
        wait_for(
            &restart_collector,
            |l| l.iter().any(|x| x == "readyok"),
            Duration::from_secs(5)
        ),
        "restarted engine never answered readyok"
    );
    let go2 = CString::new("go depth 1").unwrap();
    unsafe { rk_ffi_send_command(restart, go2.as_ptr()) };
    assert!(
        wait_for(
            &restart_collector,
            |l| l.iter().any(|x| x.starts_with("bestmove")),
            Duration::from_secs(30)
        ),
        "restarted engine never produced a bestmove"
    );
    let t1 = Instant::now();
    unsafe { rk_ffi_destroy(restart) };
    assert!(
        t1.elapsed() < Duration::from_secs(10),
        "second rk_ffi_destroy hung"
    );
}
