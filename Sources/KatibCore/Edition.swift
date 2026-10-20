import Foundation

/// An edition is Katib plus one team's extras, added at build time with
/// `build-app.sh --edition=<dir>`: settings from `edition.json`, baked into
/// Info.plist and read here, and bundled plugins. A plain source build has
/// none of them.
public enum Edition {
    /// Crash reporting is on only when an edition names a Sentry DSN.
    public static var sentryDSN: String? { value("KatibSentryDSN") }

    public static var updateManifestURL: URL? { value("KatibUpdateManifestURL").flatMap(URL.init(string:)) }

    private static func value(_ key: String) -> String? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
