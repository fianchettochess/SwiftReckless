#ifndef RECKLESS_BACKEND_H
#define RECKLESS_BACKEND_H

// RecklessBackend.h — the SINGLE source of truth for "is this build wired to a
// real Reckless engine, or to no-op stubs?".
//
// This is a PRIVATE header (it lives outside `include/`, so it is not part of
// the `CReckless` module's public interface). Both C files in the target
// include it, so the stub definitions and the `rk_backend_is_stub()` report can
// never disagree: one condition, evaluated once, used twice.
//
// INPUTS
//
//   RECKLESS_SOURCE_ARM   Defined by Package.swift for the SOURCE arm only
//                         (`SWIFTRECKLESS_FORCE_SOURCE_BUILD=1`, or any
//                         non-Apple build host). The Apple binary arm links the
//                         real engine out of RecklessFFI.xcframework and never
//                         defines this.
//
//   __ANDROID__           Set by the Android target triple. On Android the root
//                         application supplies a cross-built `libcreckless.a`
//                         as a link input, so the real symbols are present and
//                         the stubs must NOT be compiled (they would shadow
//                         them: a stub object file always wins over an archive
//                         member, which is only pulled in to satisfy a symbol
//                         that is still undefined).
//
//   RECKLESS_LINK_ARCHIVE Defined by Package.swift, per platform, when the
//                         consumer opted in with SWIFTRECKLESS_LINK_ARCHIVE=1
//                         and therefore promises a real archive on the linker
//                         search path. Currently gated to Linux and Windows;
//                         it carries exactly the same meaning as __ANDROID__
//                         above — "the real symbols are coming from elsewhere,
//                         do not define stubs".
//
// The stub arm is a deliberate, documented configuration (it keeps the
// Skip/Gradle host-introspection link working), but it is NEVER a silent one:
// `rk_backend_is_stub()` reports it to the C consumer, `RecklessBackend.current`
// reports it to the Swift consumer, and `RecklessEngine.init?` logs it.

#if defined(RECKLESS_SOURCE_ARM) && !defined(__ANDROID__) && !defined(RECKLESS_LINK_ARCHIVE)
#  define RECKLESS_BACKEND_IS_STUB 1
#else
#  define RECKLESS_BACKEND_IS_STUB 0
#endif

#endif /* RECKLESS_BACKEND_H */
