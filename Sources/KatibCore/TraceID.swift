import Foundation

/// Short random hex tag used to correlate log lines belonging to the
/// same logical operation (one bootstrap cycle, one dictation flow,
/// one hotkey press → action).
///
/// Eight hex chars is enough to avoid collisions across a single
/// session log file and short enough not to bloat the line. Format
/// chosen to match `BOOT[abcd1234]:` / `DICT[deadbeef]:` log conventions
/// used elsewhere — grep is the primary consumer of these.
public enum TraceID {
    public static func new() -> String {
        String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    }
}
