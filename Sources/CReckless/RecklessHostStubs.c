// RecklessHostStubs.c — no-op rk_ffi_* definitions for builds of the source
// arm that have no real archive (SWIFTRECKLESS_FORCE_SOURCE_BUILD=1). Not
// compiled in the XCFramework (binary) arm: Package.swift lists this file only
// in the source arm's `sources`, so it can never collide with the real symbols
// there.
//
// WHY THIS EXISTS (same pattern as Fianchetto's onnxruntime host-link fix):
// the Skip/Gradle Android build runs a host-introspection SwiftPM build on
// macOS (targeting arm64-apple-ios) with the same environment as the Android
// cross-build, including RECKLESS_LIB_DIR pointing at the aarch64-linux-
// android ELF libcreckless.a. A root manifest must not link that archive into
// the host pass: doing so fails the Mach-O build ("archive member '/' not a
// mach-o file"). When that host build fails, skipstone's transpile step is
// skipped and Gradle can assemble the APK from stale Kotlin while still
// reporting success.
//
// Fix: the root Android application passes the Rust archive only for Android;
// this dependency manifest contains no local archive path. Every platform in
// the source arm resolves rk_ffi_* against these stubs so the host dynamic
// library links. The engine is non-functional in that configuration by
// design; Apple-platform consumers use the XCFramework arm, which carries the
// real Mach-O library.
//
// ANDROID: Android used to force the real-symbols path (the root application
// supplied the archive) and excluded this file's bodies — until a shell face
// that supplied no archive (the CMP Android host) crashed with
// "cannot locate symbol rk_ffi_create" at load: Android's dlopen resolves
// every symbol when a .so loads, unlike macOS. Android now takes the stub arm
// by DEFAULT, exactly like the other source-arm platforms; a consumer that
// supplies the cross-built archive opts in with SWIFTRECKLESS_LINK_ARCHIVE=1
// + RECKLESS_LIB_DIR, which Package.swift folds into RECKLESS_LINK_ARCHIVE for
// .android too.
//
// DESKTOP/LINUX/WINDOWS: the same "the real symbols come from elsewhere"
// condition has its own trigger. A consumer that opts in with
// SWIFTRECKLESS_LINK_ARCHIVE=1 supplies a real `libcreckless.a` /
// `creckless.lib`, and Package.swift then defines RECKLESS_LINK_ARCHIVE for
// that platform. Both triggers are folded into RECKLESS_BACKEND_IS_STUB in the
// private RecklessBackend.h so this file and `rk_backend_is_stub()` can never
// disagree about which backend the build got.
//
// This guard MUST stay conservative: a stub object file beats an archive
// member (the archive is only searched for symbols still undefined), so
// compiling these bodies alongside a real archive would silently produce a
// dead engine — the exact failure this package refuses to ship.
#include "RecklessBackend.h"

#if RECKLESS_BACKEND_IS_STUB

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

#endif /* RECKLESS_BACKEND_IS_STUB */
