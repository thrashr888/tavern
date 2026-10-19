import Foundation

/// The block structure of an agent reply: enough Markdown to read a reply the way it was written
/// (headings, lists, code, quotes, tables) without a web view. Inline styling is left to
/// `AttributedString(markdown:)` per block.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(items: [String], ordered: Bool)
    case code(language: String?, text: String)
    case quote(String)
    /// Kept as its source lines and shown monospaced; columns line up well enough for agent output.
    case table(String)
    case rule

    public static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var list: (items: [String], ordered: Bool)?
        var quote: [String] = []
        var table: [String] = []
        var code: (language: String?, lines: [String])?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if let current = list { blocks.append(.list(items: current.items, ordered: current.ordered)); list = nil }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty { blocks.append(.table(table.joined(separator: "\n"))); table = [] }
        }

        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if line.hasPrefix("```") {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    open.lines.append(raw)
                    code = open
                }
                continue
            }
            if line.hasPrefix("```") {
                flush()
                let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                code = (language.isEmpty ? nil : language, [])
                continue
            }
            if line.isEmpty { flush(); continue }
            if let level = headingLevel(line) {
                flush()
                blocks.append(.heading(level: level, text: line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line == "---" || line == "***" || line == "___" { flush(); blocks.append(.rule); continue }
            if line.hasPrefix("|") {
                if table.isEmpty { flush() }
                table.append(line)
                continue
            }
            if line.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(line.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }
            if let (item, ordered) = listItem(line) {
                if list == nil || list?.ordered != ordered { flush(); list = ([], ordered) }
                list?.items.append(item)
                continue
            }
            // An indented line under a list item continues that item.
            if list != nil, raw.hasPrefix("  "), var current = list, !current.items.isEmpty {
                current.items[current.items.count - 1] += " " + line
                list = current
                continue
            }
            if list != nil || !quote.isEmpty || !table.isEmpty { flush() }
            paragraph.append(line)
        }
        if let open = code { blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> (String, Bool)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return (String(line.dropFirst(2)), false)
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return (String(rest.dropFirst(2)), true) }
        }
        return nil
    }
}
