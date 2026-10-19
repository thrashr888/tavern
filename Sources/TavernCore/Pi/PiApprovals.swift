import Foundation

/// Dialogs the user answered in Tavern, for the inspector's Approvals tab (plan 3d). Stored in the
/// event log next to the agent's thread; the transcript doesn't show them.
public enum ApprovalLog {
    public static let kind = "tavern.approval"

    public struct Entry: Equatable, Identifiable, Sendable {
        public var id: String
        public var date: Date
        public var title: String
        public var answer: String
    }

    public static func event(agentID: String, dialog: PiDialog, answer: PiDialogAnswer, date: Date = Date()) -> TavernEvent {
        let payload: JSONValue = [
            "type": "tavern_approval",
            "dialogId": .string(dialog.id),
            "title": .string(dialog.title.isEmpty ? (dialog.message ?? "Request") : dialog.title),
            "answer": .string(describe(answer)),
        ]
        return TavernEvent(
            source: EventSource.tavern,
            sourceID: "approval:\(agentID):\(dialog.id):\(UUID().uuidString)",
            threadKey: PiEntries.threadKey(agentID: agentID),
            authorAgent: "paul",
            sourceTS: date,
            receivedTS: date,
            kind: kind,
            payload: (try? payload.encoded()) ?? Data()
        )
    }

    /// Newest first.
    public static func entries(agentID: String, store: EventStore) -> [Entry] {
        let events = (try? store.events(threadKey: PiEntries.threadKey(agentID: agentID))) ?? []
        return events.filter { $0.kind == kind }.compactMap { event in
            guard let json = try? JSONValue.decode(event.payload) else { return nil }
            return Entry(id: event.sourceID, date: event.sourceTS,
                         title: json["title"]?.stringValue ?? "Request",
                         answer: json["answer"]?.stringValue ?? "")
        }.reversed()
    }

    static func describe(_ answer: PiDialogAnswer) -> String {
        switch answer {
        case .confirmed(true): return "Approved"
        case .confirmed(false): return "Declined"
        case .cancelled: return "Cancelled"
        case .value(let value): return "Answered “\(value)”"
        }
    }
}
