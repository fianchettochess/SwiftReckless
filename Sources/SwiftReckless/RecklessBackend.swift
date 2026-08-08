import CReckless

/// Which engine implementation this build of SwiftReckless is linked against.
///
/// SwiftReckless has one legitimate configuration in which there is no engine:
/// the source arm compiles `RecklessHostStubs.c` when nothing has supplied a
/// real `creckless` archive, so that a build which cannot have an engine still
/// *links* (the Skip/Gradle host-introspection pass depends on this, and a
/// Linux/Windows consumer that has not opted in must still build).
///
/// That configuration is legitimate; being unable to detect it is not. Without
/// this property a stub build is indistinguishable from a real build whose NNUE
/// network is missing — both are just `RecklessEngine.init?` returning `nil`.
///
/// ```swift
/// guard RecklessBackend.current == .real else {
///     // Do not offer Reckless features in this build; no amount of
///     // provisioning will make the engine start.
///     return
/// }
/// ```
public enum RecklessBackend: String, Sendable, CustomStringConvertible {

    /// The real Reckless engine is linked in: the Apple `RecklessFFI`
    /// XCFramework, an Android `libcreckless.a`, or a desktop archive supplied
    /// under `SWIFTRECKLESS_LINK_ARCHIVE=1`. Engine creation can succeed.
    case real

    /// No-op stubs are linked in. ``RecklessEngine/init(networkDirectory:)``
    /// always returns `nil` here, whatever the network directory contains.
    case stub

    /// The backend baked into this build. A compile-time constant read from the
    /// C bridge (`rk_backend_is_stub()`), so it is cheap and always available —
    /// including before any engine has been created.
    public static var current: RecklessBackend {
        rk_backend_is_stub() != 0 ? .stub : .real
    }

    /// Whether a `RecklessEngine` can ever start in this build.
    ///
    /// `false` means the failure is a BUILD configuration problem, not a
    /// provisioning one; report it as such rather than retrying the download.
    public static var isEngineAvailable: Bool { current == .real }

    public var description: String { rawValue }
}
