// creckless/src/lib.rs
//
// Root of the SwiftReckless Rust FFI crate.
//
// This crate exposes a minimal `extern "C"` surface that lets Swift drive
// Reckless's UCI loop in-process, mirroring the CStockfish C++ bridge in
// SwiftStockfish.
//
// The `reckless` engine crate is wired in as a pinned maintained-fork git
// dependency (see rust/Cargo.toml).  The four FFI functions in `ffi.rs` have
// real bodies: `rk_ffi_create` loads the NNUE net and spawns a thread running
// `reckless::run_io`; each UCI output line fires a per-instance C callback.

pub mod ffi;
