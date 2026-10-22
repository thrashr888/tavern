import Foundation
import XCTest
@testable import TavernCore

final class SpellbookTests: XCTestCase {
    static let indexJSON = """
    {"spells": [
      {"id": "SB-21", "name": "delivery-verification", "title": "Delivery verification",
       "description": "Delivery verification. Use when: A file or message has been delivered.", "kind": "spell",
       "owner": "wololo", "review_owner": "rook", "applies_to": ["all"], "lifecycle": "proposal", "gate": "needs-review",
       "version": 1, "path": "spells/delivery-verification/SKILL.md"},
      {"id": "SB-4", "name": "daily-sweep", "title": "Daily sweep", "description": "Daily sweep. Use when: 4pm.",
       "kind": "ritual", "owner": "rook", "review_owner": "rook", "applies_to": ["rook"], "lifecycle": "live", "gate": "none",
       "version": 3, "path": "spells/daily-sweep/SKILL.md"},
      {"id": "SB-9", "name": "old-way", "title": "Old way", "description": "Old way.", "kind": "spell",
       "owner": "rook", "review_owner": "rook", "applies_to": ["all"], "lifecycle": "retired", "gate": "none",
       "version": 2, "path": "spells/old-way/SKILL.md"}
    ]}
    """

    static let skill = """
    ---
    name: delivery-verification
    description: "Delivery verification. Use when: A file or message has been delivered."
    metadata:
      id: SB-21
    ---

    # Delivery verification

    ## When to use

    A file or message has been delivered.

    ## Steps

    1. Check the sent record.
    2. Open the result and read back
       the changed fields.
    3. Report what is verified.

    ## Done when

    The report names what was checked.

    ## Tools

    Gmail sent record
    """

    func testIndexSortsByNumberAndDecodesSnakeCase() throws {
        let index = try SpellIndex.parse(Data(Self.indexJSON.utf8))
        XCTAssertEqual(index.spells.map(\.id), ["SB-4", "SB-9", "SB-21"])
        let spell = try XCTUnwrap(index.spells.last)
        XCTAssertEqual(spell.reviewOwner, "rook")
        XCTAssertEqual(spell.appliesTo, ["all"])
        XCTAssertEqual(spell.trigger, "A file or message has been delivered")
        XCTAssertEqual(spell.citation, "SB-21 v1")
    }

    func testAppliesToFiltersByMemberAndHidesRetired() throws {
        let snapshot = SpellbookSnapshot(spells: try SpellIndex.parse(Data(Self.indexJSON.utf8)).spells)
        let rook = RosterMember(id: "rook", name: "Rook", kind: .hosted, avatarColor: "#000")
        let tally = RosterMember(id: "tally", name: "Tally", kind: .pi, avatarColor: "#000")
        XCTAssertEqual(snapshot.spells(for: rook).map(\.id), ["SB-4", "SB-21"])
        XCTAssertEqual(snapshot.spells(for: tally).map(\.id), ["SB-21"])
    }

    func testDocumentSectionsAndSteps() {
        let document = SpellDocument.parse(Self.skill)
        XCTAssertEqual(document.title, "Delivery verification")
        XCTAssertEqual(document.sections.map(\.title), ["When to use", "Steps", "Done when", "Tools"])
        XCTAssertEqual(document.steps, ["Check the sent record.", "Open the result and read back the changed fields.", "Report what is verified."])
        XCTAssertEqual(document.section("done when")?.body, "The report names what was checked.")
    }

    func testSourceComesFromTheRoster() {
        var roster = Roster(members: [], mailProjects: [])
        XCTAssertNil(SpellbookSource(roster: roster))
        roster.spellbookRepo = " https://example.com/skills.git "
        roster.spellbookBranch = ""
        XCTAssertEqual(SpellbookSource(roster: roster), SpellbookSource(repo: "https://example.com/skills.git"))
    }

    /// Clones a local repo, then follows a new commit: the same path Tavern takes with GitHub.
    func testClonesAndFollowsALocalRepo() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("spellbook-\(UUID())")
        let origin = root.appendingPathComponent("origin")
        try fm.createDirectory(at: origin.appendingPathComponent("spells/delivery-verification"), withIntermediateDirectories: true)
        try Data(Self.indexJSON.utf8).write(to: origin.appendingPathComponent("index.json"))
        try Data(Self.skill.utf8).write(to: origin.appendingPathComponent("spells/delivery-verification/SKILL.md"))
        func git(_ args: String...) async throws {
            _ = try await SpellbookRepo.git(["-C", origin.path, "-c", "user.name=Test", "-c", "user.email=test@example.com"] + args)
        }
        try await git("init", "--quiet")
        try await git("add", ".")
        try await git("commit", "--quiet", "-m", "Spells")

        let repo = SpellbookRepo(source: SpellbookSource(repo: origin.path), directory: root.appendingPathComponent("clone"))
        let before = try await repo.snapshot()
        XCTAssertNil(before)
        try await repo.sync()
        let first = try await repo.snapshot()
        XCTAssertEqual(first?.spells.count, 3)
        XCTAssertNotNil(first?.commit)
        let spell = try XCTUnwrap(first?.spell(id: "SB-21"))
        XCTAssertEqual(try repo.document(for: spell).steps.count, 3)

        let fewer = Self.indexJSON.replacingOccurrences(of: "\"SB-9\"", with: "\"SB-10\"")
        try Data(fewer.utf8).write(to: origin.appendingPathComponent("index.json"))
        try await git("commit", "--quiet", "-am", "Renumber")
        try await repo.sync()
        let second = try await repo.snapshot()
        XCTAssertNotNil(second?.spell(id: "SB-10"))
        XCTAssertNotEqual(second?.commit, first?.commit)
        try? fm.removeItem(at: root)
    }

    func testPathsCannotLeaveTheClone() {
        let repo = SpellbookRepo(source: SpellbookSource(repo: "x"), directory: URL(fileURLWithPath: "/tmp/spellbook"))
        let spell = Spell(id: "SB-1", name: "x", title: "X", description: "X.", path: "../roster.json")
        XCTAssertThrowsError(try repo.document(for: spell))
    }

    func testRunsChecklistSaveAndCountAsCasts() throws {
        let spell = try XCTUnwrap(try SpellIndex.parse(Data(Self.indexJSON.utf8)).spells.last)
        // Whole seconds: the store keeps ISO 8601 dates.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        var run = SpellRun(spell: spell, document: SpellDocument.parse(Self.skill), commit: "abc1234", agentID: "tally", startedAt: now)
        XCTAssertEqual(run.parts[0].steps.count, 3)
        XCTAssertEqual(run.parts[0].doneWhen, "The report names what was checked.")
        run.parts[0].toggle(0)
        run.parts[0].toggle(2)
        run.parts[0].toggle(0)
        run.parts[0].setNote("https://example.com/sent", for: 2)
        XCTAssertEqual(run.parts[0].checked, [2])
        XCTAssertFalse(run.allChecked)
        XCTAssertEqual(run.checkedCount, 1)
        XCTAssertEqual(run.stepCount, 3)
        XCTAssertTrue(run.summary(by: "Tally").contains("[x] Report what is verified. — https://example.com/sent"))
        let cast = SpellRun(spell: spell, document: SpellDocument.parse(Self.skill), commit: nil, agentID: "tally",
                            issue: "PAUL-9", message: "  Check the Drive link too.\n")
        XCTAssertEqual(cast.message, "Check the Drive link too.")
        XCTAssertTrue(cast.agentPrompt.hasPrefix("Please cast SB-21 v1: Delivery verification."))
        XCTAssertTrue(cast.agentPrompt.contains("spellbook_get (SB-21)"))
        XCTAssertTrue(cast.agentPrompt.hasSuffix("Check the Drive link too."))
        XCTAssertNil(SpellRun(spell: spell, document: SpellDocument.parse(Self.skill), commit: nil, agentID: nil, message: " ").message)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runs-\(UUID()).json")
        let runs = SpellRunStore(url: url)
        try runs.save(run)
        run.finishedAt = now
        try runs.save(run)
        XCTAssertEqual(runs.load(), [run])

        let store = try EventStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("runs-\(UUID()).sqlite").path)
        _ = try store.append([run.startEvent])
        let pov = ProofOfValue(store: store, now: now)
        XCTAssertEqual(pov.spells, [ProofOfValue.ToolUse(name: "SB-21", count: 1)])
    }

    func testChainedSpellIsTheLastOtherSpellTheStepsRun() {
        let document = SpellDocument.parse("""
        # Weekly update

        ## Steps

        1. Draft it.
        2. Run SB-20 on the draft, then run SB-21 to check delivery.
        """)
        XCTAssertEqual(document.chainedSpell(from: "SB-20"), "SB-21")
        XCTAssertNil(SpellDocument.parse(Self.skill).chainedSpell(from: "SB-21"))
    }

    func testCastsCountRunsStartedInTavernPerAgent() throws {
        let spell = try XCTUnwrap(try SpellIndex.parse(Data(Self.indexJSON.utf8)).spells.last)
        let store = try EventStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("casts-\(UUID()).sqlite").path)
        let run = SpellRun(spell: spell, document: SpellDocument.parse(Self.skill), commit: nil, agentID: "tally")
        _ = try store.append([run.startEvent])
        let since = Date().addingTimeInterval(-60)
        XCTAssertEqual(SpellCast.recent(store: store, agentID: "tally", since: since).map(\.spell), ["SB-21"])
        XCTAssertEqual(SpellCast.recent(store: store, agentID: "ember", since: since), [])
    }
}
