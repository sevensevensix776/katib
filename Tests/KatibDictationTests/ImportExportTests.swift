import XCTest
@testable import KatibDictation
import KatibCore

@MainActor
final class ImportExportTests: XCTestCase {

    private func engine() -> TextCorrectionEngine {
        TextCorrectionEngine(testingCorrections: CorrectionSet())
    }

    func testExportThenImportRoundtrips() throws {
        let source = engine()
        source.upsertCorrection(from: "api", to: "API", type: .dictionary)
        source.upsertCorrection(from: "gonna", to: "going to", type: .replacement)
        source.upsertCorrection(from: "hub spot", to: "HubSpot", type: .phonetic)

        let data = try source.exportData()
        let restored = engine()
        let count = try restored.importData(data, strategy: .replace)

        XCTAssertEqual(count, 3)
        XCTAssertEqual(restored.corrections.dictionary["api"], "API")
        XCTAssertEqual(restored.corrections.replacements["gonna"], "going to")
        XCTAssertEqual(restored.corrections.phonetic["hub spot"], "HubSpot")
    }

    func testMergeKeepsExistingUserEntries() throws {
        let engine = engine()
        engine.upsertCorrection(from: "mine", to: "Mine", type: .dictionary)

        var incoming = CorrectionSet()
        incoming.dictionary = ["theirs": "Theirs"]
        let data = try JSONEncoder().encode(incoming)

        try engine.importData(data, strategy: .merge)

        XCTAssertEqual(engine.corrections.dictionary["mine"], "Mine", "merge must not wipe pre-existing user entry")
        XCTAssertEqual(engine.corrections.dictionary["theirs"], "Theirs")
    }

    func testReplaceWipesExistingEntries() throws {
        let engine = engine()
        engine.upsertCorrection(from: "mine", to: "Mine", type: .dictionary)

        var incoming = CorrectionSet()
        incoming.dictionary = ["theirs": "Theirs"]
        let data = try JSONEncoder().encode(incoming)

        try engine.importData(data, strategy: .replace)

        XCTAssertNil(engine.corrections.dictionary["mine"], "replace must wipe prior user entry")
        XCTAssertEqual(engine.corrections.dictionary["theirs"], "Theirs")
    }

    func testInvalidJSONThrows() {
        let engine = engine()
        let garbage = Data("not json".utf8)
        XCTAssertThrowsError(try engine.importData(garbage, strategy: .merge))
    }
}
