import XCTest
@testable import TavernCore

final class MarkdownTableTests: XCTestCase {
    func testRowsWithoutTheSeparator() {
        let source = """
        | Id | Spell | When |
        |----|:------|-----:|
        | SB-09 | **repo-change-to-draft-pr** | Paul says go |
        | SB-10 | `a|b` | x \\| y |
        """
        XCTAssertEqual(MarkdownBlock.tableRows(source), [
            ["Id", "Spell", "When"],
            ["SB-09", "**repo-change-to-draft-pr**", "Paul says go"],
            ["SB-10", "`a|b`", "x | y"],
        ])
    }

    func testParsesFromAReply() {
        let blocks = MarkdownBlock.parse("Spells:\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nDone.")
        guard case .table(let source)? = blocks.first(where: { if case .table = $0 { return true }; return false }) else {
            return XCTFail("no table in \(blocks)")
        }
        XCTAssertEqual(MarkdownBlock.tableRows(source), [["A", "B"], ["1", "2"]])
    }
}
