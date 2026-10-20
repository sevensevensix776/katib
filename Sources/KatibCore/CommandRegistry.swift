import Foundation

/// Global catalog of `KatibCommand`s surfaced by the Command Palette. Feature
/// modules register at launch via `CommandRegistry.shared.register(...)`.
///
/// `@MainActor` because callers are all on the main thread already (AppDelegate
/// registers once during applicationDidFinishLaunching). If we ever need to
/// register from background work, switch the backing to an actor.
@MainActor
public final class CommandRegistry: ObservableObject {
    public static let shared = CommandRegistry()

    @Published public private(set) var commands: [KatibCommand] = []

    private init() {}

    public func register(_ command: KatibCommand) {
        if let idx = commands.firstIndex(where: { $0.id == command.id }) {
            commands[idx] = command
        } else {
            commands.append(command)
        }
    }

    public func register(_ many: [KatibCommand]) {
        for c in many { register(c) }
    }

    public func unregister(id: String) {
        commands.removeAll { $0.id == id }
    }

    /// Ranked query against the catalog. Empty query returns all commands
    /// ordered by section then rank.
    public func search(_ query: String, limit: Int = 100) -> [KatibCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            let sorted = commands.sorted {
                if $0.section.rawValue != $1.section.rawValue {
                    return $0.section.rawValue < $1.section.rawValue
                }
                if $0.rank != $1.rank { return $0.rank > $1.rank }
                return $0.title < $1.title
            }
            return Array(sorted.prefix(limit))
        }
        let scored = commands
            .map { ($0, $0.score(against: trimmed)) }
            .filter { $0.1 > 0 }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.title < $1.0.title
            }
        return Array(scored.prefix(limit).map(\.0))
    }
}
