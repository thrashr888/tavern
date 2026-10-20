import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A web page's card for a link in a Pi thread: title, description, site icon and hero image.
/// Images are file names in `LinkPreviewCache.folder`, already scaled down.
public struct LinkPreview: Codable, Equatable, Sendable {
    public var url: URL
    public var title: String?
    public var summary: String?
    public var siteName: String?
    public var iconFile: String?
    public var imageFile: String?
    public var fetched: Date
    /// Nothing came back (offline, timeout, not a page). Tried again after a day.
    public var failed: Bool

    public init(url: URL, title: String? = nil, summary: String? = nil, siteName: String? = nil,
                iconFile: String? = nil, imageFile: String? = nil, fetched: Date = Date(), failed: Bool = false) {
        self.url = url
        self.title = title
        self.summary = summary
        self.siteName = siteName
        self.iconFile = iconFile
        self.imageFile = imageFile
        self.fetched = fetched
        self.failed = failed
    }

    /// "example.com", without a leading "www.".
    public var domain: String { Self.domain(of: url) }
    public var displayTitle: String { title ?? domain }

    public static func domain(of url: URL) -> String {
        let host = url.host?.lowercased() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Which links Tavern may fetch a preview for. Previews are fetched without being asked, so they
/// must never reach this Mac, the LAN or the tailnet: only http(s) to public hosts.
public enum LinkPreviewPolicy {
    public static func allows(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
              var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.contains(":") {
            guard let bytes = ipv6(host) else { return false }
            return isPublic(ipv6: bytes)
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        // A numeric last label means an IPv4 address in some spelling ("10.1", "0x7f.1", "2130706433").
        if let last = labels.last, last.allSatisfy({ $0.isHexDigit || $0 == "x" }), last.first?.isNumber == true {
            guard let address = ipv4(host) else { return false }
            return isPublic(ipv4: address)
        }
        // Single-label names ("nas", "localhost") and private suffixes stay on the LAN or tailnet.
        guard labels.count > 1, !labels.contains(where: \.isEmpty) else { return false }
        return !blockedSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The links in a message worth a preview: http(s) to public hosts, each page once, in order.
    public static func previewable(in text: String, limit: Int = 4) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for url in LinkedText.links(in: text).map(LinkPreviewCache.normalized) where allows(url) && seen.insert(url).inserted {
            result.append(url)
            if result.count == limit { break }
        }
        return result
    }

    static let blockedSuffixes = ["localhost", "local", "lan", "home", "internal", "intranet", "corp",
                                  "home.arpa", "ts.net", "beta.tailscale.net"]

    /// Whether every address `host` resolves to is public, so a public-looking name can't point
    /// a fetch at this Mac or the LAN. Blocking; call off the main thread.
    public static func resolvesPublic(_ host: String) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(first) }
        var any = false
        for info in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let addr = info.pointee.ai_addr else { continue }
            switch Int32(addr.pointee.sa_family) {
            case AF_INET:
                let value = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                guard isPublic(ipv4: value) else { return false }
            case AF_INET6:
                let bytes = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
                }
                guard isPublic(ipv6: bytes) else { return false }
            default:
                continue
            }
            any = true
        }
        return any
    }

    static func ipv4(_ text: String) -> UInt32? {
        var address = in_addr()
        guard inet_aton(text, &address) != 0 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    static func ipv6(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    static func isPublic(ipv4 a: UInt32) -> Bool {
        func within(_ base: UInt32, _ bits: UInt32) -> Bool { a >> (32 - bits) == base >> (32 - bits) }
        return !(within(0x0000_0000, 8)      // 0.0.0.0/8
            || within(0x0A00_0000, 8)        // 10/8
            || within(0x6440_0000, 10)       // 100.64/10, carrier-grade NAT and Tailscale
            || within(0x7F00_0000, 8)        // loopback
            || within(0xA9FE_0000, 16)       // link-local
            || within(0xAC10_0000, 12)       // 172.16/12
            || within(0xC000_0000, 24)       // 192.0.0/24
            || within(0xC0A8_0000, 16)       // 192.168/16
            || within(0xC612_0000, 15)       // 198.18/15, benchmarking
            || within(0xE000_0000, 3))       // multicast, reserved, broadcast
    }

    static func isPublic(ipv6 b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b[0..<15].allSatisfy({ $0 == 0 }) { return false }                       // :: and ::1
        func v4(_ bytes: ArraySlice<UInt8>) -> UInt32 { bytes.reduce(0) { $0 << 8 | UInt32($1) } }
        // IPv4 inside IPv6: mapped (::ffff:a.b.c.d), compatible (::a.b.c.d), NAT64 (64:ff9b::a.b.c.d)
        // and 6to4 (2002:aabb:ccdd::) carry an address to check; Teredo hides one, so it's refused.
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF { return isPublic(ipv4: v4(b[12..<16])) }
        if b[0..<12].allSatisfy({ $0 == 0 }) { return isPublic(ipv4: v4(b[12..<16])) }
        if b[0..<12].elementsEqual([0, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0]) { return isPublic(ipv4: v4(b[12..<16])) }
        if b[0] == 0x20 && b[1] == 0x02 { return isPublic(ipv4: v4(b[2..<6])) }
        if b[0..<4].elementsEqual([0x20, 0x01, 0, 0]) { return false }                  // Teredo
        if b[0..<8].elementsEqual([0x01, 0, 0, 0, 0, 0, 0, 0]) { return false }         // 100::/64 discard
        if b[0] & 0xFE == 0xFC { return false }                                      // fc00::/7, incl. Tailscale
        if b[0] == 0xFE && b[1] & 0xC0 != 0 { return false }                         // fe80::/10, fec0::/10
        if b[0] == 0xFF { return false }                                             // multicast
        return true
    }
}

/// What a page's `<head>` says about itself in `<meta>` tags and `<title>`. LinkPresentation
/// doesn't expose a description, so Tavern reads it here.
public struct LinkMeta: Equatable, Sendable {
    public var title: String?
    public var description: String?
    public var siteName: String?
    /// The hero image and site icon, as written (possibly relative to the page).
    public var image: String?
    public var icon: String?

    public init(title: String? = nil, description: String? = nil, siteName: String? = nil,
                image: String? = nil, icon: String? = nil) {
        self.title = title
        self.description = description
        self.siteName = siteName
        self.image = image
        self.icon = icon
    }

    /// Reads only the head (or the start of the page when there's no closing tag).
    public static func parse(_ html: String) -> LinkMeta {
        let head: Substring
        if let end = html.range(of: "</head>", options: .caseInsensitive) {
            head = html[..<end.lowerBound]
        } else {
            head = html.prefix(65_536)
        }
        var tags: [String: String] = [:]
        for tag in Self.tags("meta", in: head) {
            let attributes = Self.attributes(tag)
            guard let key = (attributes["property"] ?? attributes["name"])?.lowercased(),
                  let content = attributes["content"], tags[key] == nil else { continue }
            tags[key] = content
        }
        // Icons: the largest kind first (apple-touch-icon is 180px), then the plain favicon.
        var icons: [String: String] = [:]
        for tag in Self.tags("link", in: head) {
            let attributes = Self.attributes(tag)
            guard let rel = attributes["rel"]?.lowercased(), let href = attributes["href"], !href.isEmpty,
                  !(attributes["type"]?.contains("svg") ?? false), !href.lowercased().hasSuffix(".svg") else { continue }
            for kind in rel.split(separator: " ").map(String.init) where icons[kind] == nil { icons[kind] = href }
        }
        let title = Self.title(in: head)
        func link(_ value: String?) -> String? {
            guard let value = value.map(decodeEntities)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        func clean(_ value: String?, limit: Int) -> String? {
            guard let value else { return nil }
            let text = decodeEntities(value).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty else { return nil }
            return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
        }
        return LinkMeta(
            title: clean(tags["og:title"] ?? tags["twitter:title"] ?? title, limit: 200),
            description: clean(tags["og:description"] ?? tags["twitter:description"] ?? tags["description"], limit: 300),
            siteName: clean(tags["og:site_name"], limit: 80),
            image: link(tags["og:image:secure_url"] ?? tags["og:image"] ?? tags["og:image:url"] ?? tags["twitter:image"]),
            icon: link(icons["apple-touch-icon"] ?? icons["icon"])
        )
    }

    /// The attribute text of each `<name …>` tag, scanning forward once: a page of unclosed
    /// tags can't make it backtrack. At most 200 tags, each at most 2 KB.
    static func tags(_ name: String, in html: Substring) -> [String] {
        var result: [String] = []
        var rest = html[...]
        while result.count < 200, let open = rest.range(of: "<" + name, options: .caseInsensitive) {
            rest = rest[open.upperBound...]
            guard let next = rest.first, next.isWhitespace || next == "/" else { continue }
            let window = rest.prefix(2048)
            guard let close = window.firstIndex(of: ">") else { continue }
            result.append(String(rest[..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    static func title(in html: Substring) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let start = html[open.upperBound...].prefix(256).firstIndex(of: ">") else { return nil }
        let body = html[html.index(after: start)...].prefix(2048)
        guard let end = body.range(of: "</title", options: .caseInsensitive) else { return nil }
        return String(body[..<end.lowerBound])
    }

    nonisolated(unsafe) private static let attribute = #/([A-Za-z_:\-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/#

    static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in text.matches(of: attribute) {
            let value = match.output.2 ?? match.output.3 ?? match.output.4 ?? ""
            result[match.output.1.lowercased()] = String(value)
        }
        return result
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                     "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“"]
        return text.replacing(#/&(#[xX]?[0-9A-Fa-f]+|[A-Za-z]+);/#) { match in
            let name = String(match.output.1)
            if name.hasPrefix("#") {
                let hex = name.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
                let digits = name.dropFirst(hex ? 2 : 1)
                if let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    return String(Character(scalar))
                }
                return String(match.output.0)
            }
            return named[name.lowercased()] ?? String(match.output.0)
        }
    }
}

/// Previews kept on disk, so a link is fetched once, not on every launch. Keyed by the SHA-256
/// of the address (without its #fragment), like the card cache.
public enum LinkPreviewCache {
    public static var folder: URL? { TavernPaths.file("link-previews") }

    public static func key(for url: URL) -> String {
        SHA256.hash(data: Data(normalized(url).absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The address without its fragment: "page#a" and "page#b" are one page.
    public static func normalized(_ url: URL) -> URL {
        guard url.fragment != nil, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.fragment = nil
        return parts.url ?? url
    }

    public static func load(_ url: URL) -> LinkPreview? {
        guard let file = folder?.appendingPathComponent(key(for: url) + ".json"),
              let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LinkPreview.self, from: data)
    }

    static func save(_ preview: LinkPreview) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(preview) else { return }
        try? data.write(to: folder.appendingPathComponent(key(for: preview.url) + ".json"), options: .atomic)
    }

    /// A cached image file, by the name a preview stores.
    public static func file(_ name: String?) -> URL? {
        guard let name, name.range(of: #"^[0-9a-f]{64}-(icon|image)\.(png|jpg)$"#, options: .regularExpression) != nil
        else { return nil }
        return folder?.appendingPathComponent(name)
    }
}

/// Fetches previews: the page head (title, description, image and icon tags), then the icon and
/// hero image, all through one guarded, cookie-free session. Every request, redirect included,
/// must go to a public host, checked by name, by DNS and by the address actually connected to.
/// LinkPresentation isn't used: it follows redirects and loads subresources out of reach of
/// these checks. Each address is fetched once; a failure is tried again after a day. At most two
/// previews load at a time.
public actor LinkPreviewFetcher {
    public static let shared = LinkPreviewFetcher()

    private var inFlight: [String: Task<LinkPreview?, Never>] = [:]
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    static let timeout: TimeInterval = 8

    public func preview(for url: URL) async -> LinkPreview? {
        let url = LinkPreviewCache.normalized(url)
        guard LinkPreviewPolicy.allows(url) else { return nil }
        if let cached = LinkPreviewCache.load(url), !cached.failed || cached.fetched > Date().addingTimeInterval(-86_400) {
            return cached
        }
        let key = LinkPreviewCache.key(for: url)
        if let task = inFlight[key] { return await task.value }
        let task = Task<LinkPreview?, Never> {
            await self.acquire()
            let preview = await Self.fetch(url)
            self.release()
            LinkPreviewCache.save(preview)
            return preview
        }
        inFlight[key] = task
        let preview = await task.value
        inFlight[key] = nil
        return preview
    }

    private func acquire() async {
        if running < 2 {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }

    static func fetch(_ url: URL) async -> LinkPreview {
        let key = LinkPreviewCache.key(for: url)
        var preview = LinkPreview(url: url, failed: true)
        guard let page = await get(url, limit: 65_536, kind: "html") else { return preview }
        let meta = LinkMeta.parse(String(decoding: page.data, as: UTF8.self))
        preview.title = meta.title
        preview.summary = meta.description
        preview.siteName = meta.siteName
        preview.failed = meta.title == nil && meta.description == nil
        let iconURL = URL(string: meta.icon ?? "/favicon.ico", relativeTo: page.url)?.absoluteURL
        let imageURL = meta.image.flatMap { URL(string: $0, relativeTo: page.url)?.absoluteURL }
        async let icon = image(iconURL, maxPixels: 128, as: "\(key)-icon.png")
        async let hero = image(imageURL, maxPixels: 800, as: "\(key)-image.jpg")
        preview.iconFile = await icon
        preview.imageFile = await hero
        return preview
    }

    /// An image scaled down and stored in the cache; its file name, or nil.
    static func image(_ url: URL?, maxPixels: Int, as name: String) async -> String? {
        guard let url, let file = await get(url, limit: 5_000_000, kind: "image"),
              store(file.data, maxPixels: maxPixels, as: name) else { return nil }
        return name
    }

    /// GETs `url` and reads up to `limit` bytes (images over it are dropped; a page is cut
    /// short, which is fine for its head). `kind` must be in the Content-Type. Nil unless every
    /// hop was to a public host, by name, DNS and connected address.
    static func get(_ url: URL, limit: Int, kind: String) async -> (data: Data, url: URL)? {
        guard await publicHost(url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(kind == "html" ? "text/html" : "image/*", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let guardian = RequestGuard()
        guard let (bytes, response) = try? await session.bytes(for: request, delegate: guardian) else { return nil }
        defer { bytes.task.cancel() }
        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              type.contains(kind), !type.contains("svg") else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            return nil
        }
        if kind != "html" && data.count >= limit { return nil }
        bytes.task.cancel()
        guard await guardian.connectedOnlyToPublicHosts() else { return nil }
        return (data, response.url ?? url)
    }

    /// The name passes the policy and resolves only to public addresses (blocking, so off the
    /// caller's thread).
    static func publicHost(_ url: URL) async -> Bool {
        guard LinkPreviewPolicy.allows(url), let host = url.host else { return false }
        return await Task.detached { LinkPreviewPolicy.resolvesPublic(host) }.value
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh) Tavern link preview"]
        return URLSession(configuration: config)
    }()

    /// Checks each redirect before following it, and records the addresses the task connected to,
    /// so a name that resolved public for the check but private for the connection (DNS
    /// rebinding) is caught before the response is used.
    final class RequestGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var addresses: [String?]?

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, await LinkPreviewFetcher.publicHost(url) else { return nil }
            return request
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            lock.withLock { addresses = metrics.transactionMetrics.filter { $0.resourceFetchType == .networkLoad }.map(\.remoteAddress) }
        }

        /// Waits briefly for the task's metrics; false if they don't come or name a private address.
        func connectedOnlyToPublicHosts() async -> Bool {
            for _ in 0..<40 {
                if let addresses = lock.withLock({ addresses }) {
                    return !addresses.isEmpty && addresses.allSatisfy { address in
                        guard let address else { return false }
                        if address.contains(":") { return LinkPreviewPolicy.ipv6(address).map(LinkPreviewPolicy.isPublic(ipv6:)) ?? false }
                        return LinkPreviewPolicy.ipv4(address).map(LinkPreviewPolicy.isPublic(ipv4:)) ?? false
                    }
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }
    }

    /// Scales an image down to `maxPixels` on its long side and writes it to the cache.
    static func store(_ data: Data, maxPixels: Int, as name: String) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary),
              let file = LinkPreviewCache.file(name) else { return false }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let type = (name.hasSuffix(".png") ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, type, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
