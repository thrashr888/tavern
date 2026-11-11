import Foundation
import Combine

/// Local, input-scoped drafts. Reading/restoring never dispatches a message.
@MainActor
public final class MessageDraftStore: ObservableObject {
    public static let shared = MessageDraftStore()
    @Published private var values: [String: String]
    private let defaults: UserDefaults
    private let storageKey = "tavern.message-drafts.v1"
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        values = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }
    public func text(for key: String) -> String { values[key] ?? "" }
    public func set(_ text: String, for key: String) {
        if text.isEmpty { values.removeValue(forKey: key) } else { values[key] = text }
        defaults.set(values, forKey: storageKey)
    }
    public func clear(_ key: String, ifMatching submitted: String) {
        if text(for: key) == submitted { set("", for: key) }
    }
}
