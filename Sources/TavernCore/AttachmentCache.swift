import CryptoKit
import Foundation

/// Local copies of images the user sends, named by content hash like the durable host names its
/// copies, so a thread can show an image inline even when the agent runs on another machine.
public enum AttachmentCache {
    public static var folder: URL? {
        TavernPaths.file("attachments")
    }

    /// The host's file name for these bytes: the first 16 hex digits of their SHA-256.
    public static func name(for data: Data, ext: String) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16) + "." + ext
    }

    public static func store(_ image: PiImage) {
        guard let folder, let ext = extensions[image.mimeType] else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? image.data.write(to: folder.appendingPathComponent(name(for: image.data, ext: ext)), options: .atomic)
    }

    public static func localPath(for image: PiImage) -> String? {
        guard let folder, let ext = extensions[image.mimeType] else { return nil }
        return folder.appendingPathComponent(name(for: image.data, ext: ext)).path
    }

    /// A file to show for an image path named in a message. Message text isn't trusted with
    /// paths: only Tavern's own copies (content-hash names) and Messages' attachment store resolve.
    public static func localFile(for path: String) -> URL? {
        let name = (path as NSString).lastPathComponent
        if name.range(of: #"^[0-9a-f]{16}\.(png|jpg|gif|webp|heic)$"#, options: .regularExpression) != nil,
           let folder, FileManager.default.isReadableFile(atPath: folder.appendingPathComponent(name).path) {
            return folder.appendingPathComponent(name)
        }
        let messages = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/Attachments").path + "/"
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        if resolved.path.hasPrefix(messages), FileManager.default.isReadableFile(atPath: resolved.path) { return resolved }
        return nil
    }

    /// The image paths in a message the host annotated, and the text before them.
    public static func split(_ text: String) -> (text: String, paths: [String]) {
        guard let range = text.range(of: "\n\nAttached image") else { return (text, []) }
        let paths = text[range.lowerBound...].components(separatedBy: "\n")
            .filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
        return (String(text[..<range.lowerBound]), paths)
    }

    static let extensions = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "image/heic": "heic"]
}
