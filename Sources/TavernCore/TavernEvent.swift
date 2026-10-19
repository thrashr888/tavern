import Foundation

/// One row of Tavern's append-only event log.
///
/// `(source, sourceID)` is the dedup key: a Gmail message id, a Pi `sessionId:entryId`, and so on.
/// `threadKey` is Tavern's own id for the thread, never an external id, so new sources can be added
/// without a migration (plan section 3e).
public struct TavernEvent: Equatable, Sendable {
    public var source: String
    public var sourceID: String
    public var threadKey: String
    public var authorAgent: String?
    /// When the source says it happened (Gmail `internalDate`, Pi entry `timestamp`). Sort key.
    public var sourceTS: Date
    /// When Tavern stored it.
    public var receivedTS: Date
    public var kind: String
    public var payload: Data

    public init(
        source: String,
        sourceID: String,
        threadKey: String,
        authorAgent: String? = nil,
        sourceTS: Date,
        receivedTS: Date = Date(),
        kind: String,
        payload: Data = Data()
    ) {
        self.source = source
        self.sourceID = sourceID
        self.threadKey = threadKey
        self.authorAgent = authorAgent
        self.sourceTS = sourceTS
        self.receivedTS = receivedTS
        self.kind = kind
        self.payload = payload
    }
}

/// Known event sources. Strings so a later adapter can add its own without touching this file.
public enum EventSource {
    public static let pi = "pi"
    public static let gmail = "gmail"
    public static let tavern = "tavern"
}
