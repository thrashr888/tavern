import Foundation
import XCTest
@testable import TavernCore

final class DecisionModelTests: XCTestCase {
    private let questions: [String: DecisionQuestion] = [
        "project": .choice(instructions: "Which project?", options: [(key: "p1", description: "Tavern"), (key: "none", description: nil)]),
        "urgent": .noul(instructions: "Is it urgent?"),
    ]

    func testParsesAndScoresAnswers() throws {
        let raw: JSONValue = ["answers": [
            "project": ["type": "choice", "choice": "p1", "probabilities": ["p1": .number(0.9), "none": .number(0.1)]],
            "urgent": ["type": "noul", "noul": .number(0.2)],
        ]]
        let answers = try DecisionBackend.parse(raw, questions: questions)
        XCTAssertEqual(answers["project"]?.choice, "p1")
        XCTAssertEqual(answers["project"]?.confidence ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(answers["urgent"], .noul(0.2))
        XCTAssertEqual(DecisionSuggestions.pick("project", in: answers), "p1")
        XCTAssertNil(DecisionSuggestions.pick("project", in: answers, minConfidence: 0.9))
    }

    func testRejectsAnswersThatDontMatchTheQuestion() {
        let unknown: JSONValue = ["answers": [
            "project": ["type": "choice", "choice": "p9", "probabilities": ["p9": .number(1)]],
            "urgent": ["type": "noul", "noul": .number(0.2)],
        ]]
        XCTAssertThrowsError(try DecisionBackend.parse(unknown, questions: questions))
        let missing: JSONValue = ["answers": ["urgent": ["type": "noul", "noul": .number(0.2)]]]
        XCTAssertThrowsError(try DecisionBackend.parse(missing, questions: questions))
    }

    func testSpellQuestionsComeInBatchesOfTwelveAndNoneNeverWins() {
        let spells = (1...29).map { Spell(id: "SB-\($0)", name: "s\($0)", title: "S\($0)", description: "S\($0).", path: "x") }
        let questions = DecisionSuggestions.spellQuestions(for: spells)
        XCTAssertEqual(questions.count, 3)
        XCTAssertEqual(questions["spell0"]?.optionKeys.count, 13)
        XCTAssertEqual(questions["spell2"]?.optionKeys.count, 6)
        let answers: [String: DecisionAnswer] = [
            "spell0": .choice("none", probabilities: [:], confidence: 0.95),
            "spell1": .choice("SB-20", probabilities: [:], confidence: 0.75),
            "spell2": .choice("SB-27", probabilities: [:], confidence: 0.5),
        ]
        XCTAssertEqual(DecisionSuggestions.spell(from: answers)?.id, "SB-20")
    }

    func testPrefersClefFlashThenLargerTags() {
        XCTAssertEqual(DecisionBackend.pick(["tev1:4b", "clef:latest", "clef-flash:latest"]), "clef-flash:latest")
        XCTAssertEqual(DecisionBackend.pick(["tev1:0.8b", "tev1:4b"]), "tev1:4b")
        XCTAssertNil(DecisionBackend.pick([]))
    }

    func testJevKeyFromTheSharedFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("jev-\(UUID())")
        XCTAssertNil(DecisionBackend.jev(environment: [:], home: home))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/typesafe"), withIntermediateDirectories: true)
        try "sk-test\n".write(to: home.appendingPathComponent(".config/typesafe/api-key"), atomically: true, encoding: .utf8)
        let jev = try XCTUnwrap(DecisionBackend.jev(environment: [:], home: home))
        XCTAssertEqual(jev.key, "sk-test")
        XCTAssertFalse(jev.isLocal)
        XCTAssertEqual(DecisionBackend.jev(environment: ["TYPESAFE_API_KEY": "sk-env"], home: home)?.key, "sk-env")
    }
}
