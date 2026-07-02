// RecklessHostStubs.c — no-op rk_ffi_* definitions for NON-Android builds of
// the SOURCE arm (SWIFTRECKLESS_FORCE_SOURCE_BUILD=1). NOT compiled in the
// xcframework (binary) arm — Package.swift only lists this file in the source
// arm's `sources`, so it can never collide with the real symbols there.
//
// WHY THIS EXISTS (same pattern as Fianchetto's onnxruntime host-link fix):
// the Skip/gradle Android build runs a HOST-introspection SwiftPM build on
// macOS (targeting arm64-apple-ios) with the SAME environment as the Android
// cross-build — including RECKLESS_LIB_DIR pointing at the aarch64-linux-
// android ELF libcreckless.a. Linking that ELF archive into a Mach-O build
// fails ("archive member '/' not a mach-o file"), and when that host build
// fails, skipstone's transpile step is skipped and gradle silently assembles
// the APK from STALE Kotlin while still reporting BUILD SUCCESSFUL.
//
// Fix: Package.swift links the real Rust staticlib ONLY for Android
// (.when(platforms: [.android])); every other platform in the source arm
// resolves rk_ffi_* against these stubs so the host dylib links. The engine
// is non-functional in that configuration by design — Apple-platform
// consumers use the xcframework arm, which carries the real Mach-O library.
//
// `__ANDROID__` is the reliable host-vs-device discriminator here (defined by
// the aarch64-linux-android target triple; never on the host pass).
#if !defined(__ANDROID__)

#include <stddef.h>
#include "RecklessBridge.h"

RKEngineRef rk_ffi_create(const char *network_path) {
    (void)network_path;
    return NULL;  // RecklessEngine.init? sees NULL and fails gracefully.
}

void rk_ffi_destroy(RKEngineRef engine) {
    (void)engine;
}

void rk_ffi_set_output_callback(RKEngineRef engine,
                                RKOutputCallback callback,
                                const void *context) {
    (void)engine; (void)callback; (void)context;
}

void rk_ffi_send_command(RKEngineRef engine, const char *command) {
    (void)engine; (void)command;
}

#endif /* !__ANDROID__ */
