/// Spike: historical proof-of-concept that Reckless can run in-process with fd 1
/// (stdout) redirected to a pipe, capturing engine output.
///
/// NOTE: This spike demonstrates the OLD fd-redirect model.  The production FFI
/// (ffi.rs) now uses per-instance I/O (reckless::run_io + mpsc channel + output
/// closure) with NO fd redirection.  This spike is retained as a regression
/// baseline: it proves that reckless::run() with a VecDeque buffer still works
/// (the binary/stdin path is unchanged).
///
/// Model:
///   1. Save the real fd 1 (dup it aside).
///   2. Create a pipe (read_end, write_end).
///   3. dup2 write_end → fd 1.  Close write_end (fd 1 is now the engine's stdout).
///   4. Spin a reader thread draining read_end into a Vec<String>.
///   5. Call reckless::run(["uci", "quit"]) via buffer — CLI mode, no stdin needed.
///      The engine processes "uci" (emits id/options/uciok to stdout) then "quit".
///   6. After run() returns: flush, dup2 saved_stdout → fd 1, join reader thread.
///   7. Assert PASS if captured lines contain "uciok" and "id name Reckless".
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::os::unix::io::FromRawFd;

fn main() {
    // The NNUE net is no longer baked into the binary — load it at startup.
    let net_path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/networks/v54-5478683c.nnue"
    );
    if !std::path::Path::new(net_path).exists() {
        eprintln!(
            "SPIKE FAIL: NNUE net not found at {net_path}\n\
             Download it with:\n  \
             curl -L -o {net_path} \
             https://github.com/codedeliveryservice/RecklessNetworks/releases/download/networks/v54-5478683c.nnue"
        );
        std::process::exit(1);
    }
    let net_bytes = std::fs::read(net_path).expect("failed to read NNUE net");
    reckless::nnue::load_network(&net_bytes).unwrap_or_else(|e| {
        if !e.contains("already loaded") {
            panic!("load_network failed: {e}");
        }
    });
    // ── 1. Save real stdout ────────────────────────────────────────────────────
    let saved_stdout_fd = unsafe { libc::dup(libc::STDOUT_FILENO) };
    assert!(saved_stdout_fd >= 0, "dup(stdout) failed");

    // ── 2. Create pipe ─────────────────────────────────────────────────────────
    let mut pipe_fds: [libc::c_int; 2] = [-1; 2];
    let ret = unsafe { libc::pipe(pipe_fds.as_mut_ptr()) };
    assert_eq!(ret, 0, "pipe() failed");
    let (pipe_read, pipe_write) = (pipe_fds[0], pipe_fds[1]);

    // ── 3. dup2 write-end → fd 1 ───────────────────────────────────────────────
    let ret = unsafe { libc::dup2(pipe_write, libc::STDOUT_FILENO) };
    assert_eq!(ret, libc::STDOUT_FILENO, "dup2(pipe_write, stdout) failed");
    // Close the extra copy of write_end (fd 1 is now the alias we keep).
    unsafe { libc::close(pipe_write) };

    // ── 4. Reader thread: drain read-end into Vec<String> ─────────────────────
    let reader = std::thread::spawn(move || {
        let mut file = unsafe { std::fs::File::from_raw_fd(pipe_read) };
        let mut buf = String::new();
        file.read_to_string(&mut buf).expect("read pipe failed");
        buf.lines().map(|l| l.to_string()).collect::<Vec<String>>()
    });

    // ── 5. Run engine via buffer (CLI mode — no stdin involvement) ─────────────
    //
    // VecDeque non-empty → message_loop enters Mode::Cli.  It drains the buffer
    // then exits.  The listener thread is spawned but immediately blocks on stdin
    // (which we have NOT redirected); it will be leaked as a detached thread,
    // which is acceptable for a spike.
    let buffer: VecDeque<String> = ["uci", "quit"].iter().map(|s| s.to_string()).collect();

    // The engine runs synchronously on this thread and exits after "quit".
    reckless::run(buffer);

    // ── 6. Restore stdout, signal EOF to reader ────────────────────────────────
    // Flush the Rust IO buffers first (stdout is still fd 1 = pipe_write alias).
    let _ = std::io::stdout().flush();

    // Restore fd 1 to the real terminal/saved stdout.
    let ret = unsafe { libc::dup2(saved_stdout_fd, libc::STDOUT_FILENO) };
    assert_eq!(ret, libc::STDOUT_FILENO, "dup2 restore failed");
    unsafe { libc::close(saved_stdout_fd) };

    // fd 1 (the alias of pipe_write) was already closed when we restored it.
    // All write-ends of the pipe are now closed → reader thread will see EOF.

    // ── 7. Collect and evaluate ────────────────────────────────────────────────
    let lines = reader.join().expect("reader thread panicked");

    let has_uciok = lines.iter().any(|l| l == "uciok");
    let has_id_name = lines.iter().any(|l| l.starts_with("id name Reckless"));

    // Print summary to the restored real stdout.
    println!("\n── Captured engine output ({} lines) ──────────────────", lines.len());
    for line in &lines {
        println!("  {line}");
    }
    println!("────────────────────────────────────────────────────────");
    println!("has 'uciok'         : {has_uciok}");
    println!("has 'id name Reckless': {has_id_name}");

    if has_uciok && has_id_name {
        println!("\nSPIKE PASS — fd1 redirect captured Reckless UCI output in-process");
        std::process::exit(0);
    } else {
        println!("\nSPIKE FAIL — expected output not found");
        std::process::exit(1);
    }
}
