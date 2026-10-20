import Foundation

/// Pure value type capturing the three permissions Katib needs. The
/// coordinator that gates Katib's dangerous setup (transcriber, hotkey
/// taps, audio engine) reads this on launch and on every poll tick.
///
/// Lives in KatibCore — separate from `PermissionSnapshot.current()`
/// in the executable target — so the value type + transition decision
/// logic can be unit-tested without touching the OS APIs.
public struct PermissionSnapshot: Equatable, Sendable {
    public let mic: Bool
    public let speech: Bool
    public let accessibility: Bool

    public static let denied = PermissionSnapshot(mic: false, speech: false, accessibility: false)
    public static let granted = PermissionSnapshot(mic: true, speech: true, accessibility: true)

    public init(mic: Bool, speech: Bool, accessibility: Bool) {
        self.mic = mic
        self.speech = speech
        self.accessibility = accessibility
    }

    public var allGranted: Bool { mic && speech && accessibility }

    public var summary: String {
        "mic=\(mic) speech=\(speech) a11y=\(accessibility)"
    }
}

/// State of the bootstrap coordinator. Pure enum so tests can drive
/// the decision function directly. `bootstrapping` and `bootstrapped`
/// are sub-states of "permissions are/were sufficient" — telling them
/// apart matters for "should we kick off bootstrap or has it already
/// run."
public enum BootstrapState: Equatable, Sendable, CustomStringConvertible {
    case waiting
    case bootstrapping
    case bootstrapped

    public var description: String {
        switch self {
        case .waiting: return "waiting"
        case .bootstrapping: return "bootstrapping"
        case .bootstrapped: return "bootstrapped"
        }
    }
}

/// What the coordinator should do given current state + a fresh
/// permission snapshot. Pure function — no side effects, no OS calls,
/// fully testable.
public enum BootstrapAction: Equatable, Sendable {
    /// Already in the right state, do nothing.
    case noop
    /// Run bootstrap closure. Move state to `.bootstrapping`.
    case advance
    /// Run teardown closure. Move state to `.waiting`.
    case retreat(reason: String)
    /// Cancel the in-flight bootstrap task. Move state to `.waiting`.
    case cancel(reason: String)
}

/// Decide the action given current state + snapshot. Pure.
///
/// Why this is its own function: tests can hammer every (state,
/// snapshot) cell without standing up timers, AppKit, or the audio
/// pipeline. If a future change to the state machine breaks an edge
/// (e.g. forgetting to handle "all-granted while already bootstrapped"
/// as a noop), the test fails immediately rather than at 3am on a
/// teammate's machine.
public func bootstrapAction(
    from state: BootstrapState,
    snapshot: PermissionSnapshot
) -> BootstrapAction {
    switch (state, snapshot.allGranted) {
    case (.waiting, true):
        return .advance
    case (.bootstrapped, false):
        return .retreat(reason: "permission revoked while ready (\(snapshot.summary))")
    case (.bootstrapping, false):
        return .cancel(reason: "permission revoked during bootstrap (\(snapshot.summary))")
    default:
        return .noop
    }
}
