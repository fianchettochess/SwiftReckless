// creckless/src/lib.rs
//
// Root of the SwiftReckless Rust FFI crate.
//
// This crate exposes a minimal `extern "C"` surface that lets Swift drive
// Reckless's UCI loop in-process, mirroring the CStockfish C++ bridge in
// SwiftStockfish.
//
// STATUS: STUBBED — the `reckless` engine crate is not yet wired in as a
// dependency (see rust/Cargo.toml TODO).  The four FFI functions in `ffi.rs`
// are real declarations with the correct ABI; their bodies are stubs that
// return NULL / no-op until the engine dependency is added.

pub mod ffi;
