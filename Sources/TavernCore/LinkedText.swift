import Foundation

/// Plain text with its web addresses made clickable. The link is the address as written, so
/// nothing hides where it goes; only http and https count.
public enum LinkedText {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    public static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector else { return result }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result)
            else { continue }
            result[lower..<upper].link = url
        }
        return result
    }

    /// The addresses `attributed` links, in order (for tests and previews).
    public static func links(in text: String) -> [URL] {
        attributed(text).runs.compactMap(\.link)
    }
}
