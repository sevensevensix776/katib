import XCTest
@testable import KatibDictation
import KatibCore

@MainActor
final class TextCorrectionEngineTests: XCTestCase {

    // MARK: - Helpers

    private func engine(
        replacements: [String: String] = [:],
        dictionary: [String: String] = [:],
        phonetic: [String: String] = [:]
    ) -> TextCorrectionEngine {
        var set = CorrectionSet()
        set.replacements = replacements
        set.dictionary = dictionary
        set.phonetic = phonetic
        return TextCorrectionEngine(testingCorrections: set)
    }

    // MARK: - Empty + trivial

    func testEmptyStringReturnsEmpty() {
        XCTAssertEqual(engine().correct(""), "")
        XCTAssertEqual(engine().correct("   "), "")
    }

    func testAddsEndingPunctuation() {
        XCTAssertEqual(engine().correct("hello world"), "Hello world.")
    }

    func testPreservesExistingPunctuation() {
        XCTAssertEqual(engine().correct("hello world."), "Hello world.")
        XCTAssertEqual(engine().correct("hello world!"), "Hello world!")
    }

    func testCapitalizesFirstLetter() {
        XCTAssertEqual(engine().correct("hello"), "Hello.")
    }

    func testStandaloneIBecomesUppercase() {
        XCTAssertEqual(engine().correct("i think i am"), "I think I am.")
    }

    // MARK: - Dictionary corrections

    func testDictionaryUppercasesAcronym() {
        let e = engine(dictionary: ["api": "API"])
        XCTAssertEqual(e.correct("we use api"), "We use API.")
    }

    func testDictionaryPreservesCamelCase() {
        let e = engine(dictionary: ["typescript": "TypeScript"])
        XCTAssertEqual(e.correct("i write typescript"), "I write TypeScript.")
    }

    func testDictionaryDoesNotMatchWordMiddles() {
        let e = engine(dictionary: ["api": "API"])
        // "rapid" contains "api" but should not be replaced (word boundary).
        XCTAssertEqual(e.correct("rapid growth"), "Rapid growth.")
    }

    func testDictionaryIsCaseInsensitive() {
        let e = engine(dictionary: ["api": "API"])
        XCTAssertEqual(e.correct("ship the API and the Api"), "Ship the API and the API.")
    }

    func testDictionarySkipsCommentKeys() {
        let e = engine(dictionary: ["_comment_example": "IGNORE", "api": "API"])
        let out = e.correct("use the api")
        XCTAssertTrue(out.contains("API"))
        XCTAssertFalse(out.contains("IGNORE"))
    }

    // MARK: - Replacements

    func testReplacementRewritesWord() {
        let e = engine(replacements: ["gonna": "going to"])
        XCTAssertEqual(e.correct("i am gonna leave"), "I am going to leave.")
    }

    // MARK: - Phonetic

    func testPhoneticReplacesMultiWordPhrase() {
        let e = engine(phonetic: ["hub spot": "HubSpot"])
        XCTAssertEqual(e.correct("we use hub spot"), "We use HubSpot.")
    }

    func testPhoneticIsCaseInsensitive() {
        let e = engine(phonetic: ["hub spot": "HubSpot"])
        XCTAssertEqual(e.correct("Hub Spot is great"), "HubSpot is great.")
    }

    // MARK: - Filler removal

    func testRemovesUm() {
        XCTAssertEqual(engine().correct("um i think so"), "I think so.")
    }

    func testRemovesMidSentenceUh() {
        let out = engine().correct("i, uh, think so")
        XCTAssertFalse(out.lowercased().contains(" uh "))
        XCTAssertTrue(out.contains("think"))
    }

    func testRemovesYouKnowAtSentenceStart() {
        let out = engine().correct("you know, i think so")
        XCTAssertFalse(out.lowercased().contains("you know"))
    }

    func testRemovesHonestlyAtSentenceStart() {
        let out = engine().correct("honestly, it works")
        XCTAssertFalse(out.lowercased().contains("honestly"))
    }

    // MARK: - Question marks

    func testQuestionWordsGetQuestionMark() {
        XCTAssertTrue(engine().correct("what is this").hasSuffix("?"))
        XCTAssertTrue(engine().correct("how does it work").hasSuffix("?"))
        XCTAssertTrue(engine().correct("is this a test").hasSuffix("?"))
    }

    func testNonQuestionsGetPeriod() {
        XCTAssertTrue(engine().correct("the cat sat").hasSuffix("."))
    }

    // MARK: - Sentence breaking + capitalization after periods

    func testCapitalizesAfterSentenceEnd() {
        // Correction engine splits on ". " and capitalizes the next letter.
        let out = engine().correct("first. second thing")
        XCTAssertTrue(out.contains("Second"))
    }

    // MARK: - Spacing cleanup

    func testCollapsesDoubleSpaces() {
        XCTAssertEqual(engine().correct("hello  world"), "Hello world.")
    }

    func testRemovesSpaceBeforePunctuation() {
        XCTAssertEqual(engine().correct("hello ."), "Hello.")
    }

    // MARK: - Counts + totalCount

    func testTotalCount() {
        let e = engine(
            replacements: ["a": "b"],
            dictionary: ["c": "d", "e": "f"],
            phonetic: ["g h": "G-H"]
        )
        XCTAssertEqual(e.totalCount, 4)
    }

    // MARK: - Upsert + remove

    func testUpsertAddsThenOverwrites() {
        let e = engine()
        e.upsertCorrection(from: "foo", to: "bar", type: .dictionary)
        XCTAssertEqual(e.corrections.dictionary["foo"], "bar")
        e.upsertCorrection(from: "foo", to: "baz", type: .dictionary)
        XCTAssertEqual(e.corrections.dictionary["foo"], "baz")
    }

    func testUpsertTrimsWhitespace() {
        let e = engine()
        e.upsertCorrection(from: "  foo  ", to: "  bar  ", type: .dictionary)
        XCTAssertEqual(e.corrections.dictionary["foo"], "bar")
    }

    func testUpsertRejectsEmpty() {
        let e = engine()
        e.upsertCorrection(from: "", to: "bar", type: .dictionary)
        e.upsertCorrection(from: "foo", to: "", type: .dictionary)
        XCTAssertTrue(e.corrections.dictionary.isEmpty)
    }

    func testRemoveDeletesEntry() {
        let e = engine(dictionary: ["foo": "bar"])
        e.removeCorrection(key: "foo", type: .dictionary)
        XCTAssertNil(e.corrections.dictionary["foo"])
    }

    // MARK: - Codable roundtrip of CorrectionSet

    func testCorrectionSetCodableRoundtrip() throws {
        var original = CorrectionSet()
        original.replacements = ["gonna": "going to"]
        original.dictionary = ["api": "API"]
        original.phonetic = ["hub spot": "HubSpot"]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CorrectionSet.self, from: data)

        XCTAssertEqual(decoded.replacements, original.replacements)
        XCTAssertEqual(decoded.dictionary, original.dictionary)
        XCTAssertEqual(decoded.phonetic, original.phonetic)
    }

    func testCorrectionSetDecodesMissingBuckets() throws {
        // Partial JSON — decoder should fill missing buckets with [:] instead of throwing.
        let partial = #"{"dictionary": {"api": "API"}}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CorrectionSet.self, from: partial)

        XCTAssertEqual(decoded.dictionary, ["api": "API"])
        XCTAssertTrue(decoded.replacements.isEmpty)
        XCTAssertTrue(decoded.phonetic.isEmpty)
    }

    // MARK: - Recognition terms (contextual strings)

    private func terms(phonetic: [String: String] = [:], _ tiers: [String: String]..., limit: Int = 100) -> [String] {
        TextCorrectionEngine.recognitionTerms(phonetic: phonetic, ranked: tiers, limit: limit)
    }

    func testRecognitionTermsPutPhoneticTargetsFirstAndDedupe() {
        let t = terms(phonetic: ["ack me": "Acme", "hub spot": "HubSpot"],
                      ["acme": "Acme", "katib": "Katib"])
        XCTAssertEqual(t, ["Acme", "HubSpot", "Katib"])
    }

    func testRecognitionTermsRankTiersInOrder() {
        // The plugin tier wins slots over the tail (auto-learned identifiers).
        let t = terms(["zephyr": "ZEPHYR"], ["aaa": "AardvarkService"], limit: 1)
        XCTAssertEqual(t, ["ZEPHYR"])
    }

    func testRecognitionTermsSkipShortAcronymsButKeepNumbersAndLongCaps() {
        let t = terms(["api": "API", "prs": "PRs", "ec2": "EC2", "776": "776", "zephyr": "ZEPHYR"])
        XCTAssertEqual(t, ["776", "ZEPHYR"])
    }

    func testRecognitionTermsAreCapped() {
        var dict: [String: String] = [:]
        for i in 0..<150 { dict["w\(i)"] = "Word\(i)" }
        XCTAssertEqual(terms(dict).count, 100)
        XCTAssertEqual(terms(dict, limit: 7).count, 7)
    }

    private func pluginFolder(id: String, dictionary: String, syncURL: String? = nil) throws -> (Plugin, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("katib-dict-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sync = syncURL.map { #","syncURL":"\#($0)""# } ?? ""
        try #"{"id":"\#(id)","name":"\#(id)","dictionary":{"file":"dictionary.json"\#(sync)}}"#
            .write(to: folder.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        try dictionary.write(to: folder.appendingPathComponent("dictionary.json"), atomically: true, encoding: .utf8)
        return (try XCTUnwrap(PluginRegistry.load(from: [root]).first), root.appendingPathComponent("cache"))
    }

    /// The synced copy wins over the folder's file only while it came from
    /// the plugin's current syncURL; a plugin without one never reads it.
    func testSyncedCopyCountsOnlyForTheCurrentSyncURL() throws {
        let (plugin, cache) = try pluginFolder(id: "team", dictionary: #"{"dictionary":{"zeph":"Zephyr"}}"#,
                                               syncURL: "https://example.com/d.json")
        XCTAssertEqual(PluginDictionaries.merged([plugin], cacheRoot: cache).dictionary, ["zeph": "Zephyr"])
        let dir = cache.appendingPathComponent("team")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"dictionary":{"zeph":"ZEPHYR"}}"#.write(to: dir.appendingPathComponent("dictionary.json"),
                                                       atomically: true, encoding: .utf8)
        try "https://example.com/d.json".write(to: dir.appendingPathComponent("source"), atomically: true, encoding: .utf8)
        XCTAssertEqual(PluginDictionaries.merged([plugin], cacheRoot: cache).dictionary, ["zeph": "ZEPHYR"])
        let (local, _) = try pluginFolder(id: "team", dictionary: #"{"dictionary":{"zeph":"Local"}}"#)
        XCTAssertEqual(PluginDictionaries.merged([local], cacheRoot: cache).dictionary, ["zeph": "Local"])
    }

    /// CorrectionSet's decoder turns any JSON into an empty set; a sync must
    /// not replace a good dictionary with an error body.
    func testDictionaryValidationRejectsErrorBodiesAndWrongShapes() {
        XCTAssertNil(PluginDictionaries.validated(Data(#"{"error":"rate limited"}"#.utf8)))
        XCTAssertNil(PluginDictionaries.validated(Data(#"{"dictionary":["wrong shape"]}"#.utf8)))
        XCTAssertNil(PluginDictionaries.validated(Data("<html>".utf8)))
        XCTAssertEqual(PluginDictionaries.validated(Data(#"{"_meta":{"v":1},"dictionary":{"a":"A"}}"#.utf8))?.dictionary, ["a": "A"])
    }

    /// The user's file gets only their changes: never a plugin's entries, and
    /// a deleted base entry as "": so removing a plugin removes its entries.
    func testUserLayerHoldsOnlyTheUsersChanges() {
        var base = CorrectionSet()
        base.dictionary = ["zeph": "Zephyr", "acme": "Acme"]
        var merged = base
        merged.dictionary["mine"] = "Mine"          // added
        merged.dictionary["acme"] = "ACME"          // changed
        merged.dictionary.removeValue(forKey: "zeph") // deleted
        let user = TextCorrectionEngine.userLayer(merged: merged, base: base)
        XCTAssertEqual(user.dictionary, ["mine": "Mine", "acme": "ACME", "zeph": ""])
        var reloaded = base
        for (k, v) in user.dictionary { reloaded.dictionary[k] = v }
        XCTAssertEqual(TextCorrectionEngine.droppingDisabled(reloaded).dictionary, ["mine": "Mine", "acme": "ACME"])
    }

    /// A plugin can ship `dictionary-tests.json` to guard its own entries:
    ///   {"terms": ["Name", …], "cases": [{"say": "…", "expect": "…", "notContains": ["…"]}]}
    /// Runs every plugin under KATIB_TEST_PLUGINS (a Plugins folder); skipped without it.
    func testPluginDictionaryTests() throws {
        guard let dir = ProcessInfo.processInfo.environment["KATIB_TEST_PLUGINS"] else {
            throw XCTSkip("set KATIB_TEST_PLUGINS=<Plugins folder> to run plugin dictionary tests")
        }
        struct Spec: Decodable {
            struct Case: Decodable { let say: String; let expect: String?; let notContains: [String]? }
            let terms: [String]?
            let cases: [Case]?
        }
        let plugins = PluginRegistry.load(from: [URL(fileURLWithPath: dir)])
        var ran = 0
        for plugin in plugins {
            let specURL = plugin.folder.appendingPathComponent("dictionary-tests.json")
            guard let data = try? Data(contentsOf: specURL) else { continue }
            let spec = try JSONDecoder().decode(Spec.self, from: data)
            let set = try XCTUnwrap(PluginDictionaries.load(plugin, cacheRoot: URL(fileURLWithPath: "/nonexistent")))
            let t = terms(phonetic: set.phonetic, set.dictionary)
            XCTAssertLessThanOrEqual(t.count, 100)
            for name in spec.terms ?? [] { XCTAssertTrue(t.contains(name), "\(plugin.id): missing term \(name)") }
            let e = TextCorrectionEngine(testingCorrections: set)
            for c in spec.cases ?? [] {
                let out = e.correct(c.say)
                if let expect = c.expect { XCTAssertEqual(out, expect, "\(plugin.id)") }
                for bad in c.notContains ?? [] { XCTAssertFalse(out.contains(bad), "\(plugin.id): \(out)") }
            }
            ran += 1
        }
        XCTAssertGreaterThan(ran, 0, "no plugin in \(dir) has dictionary-tests.json")
    }
}
