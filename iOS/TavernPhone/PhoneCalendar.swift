import EventKit
import Foundation

/// Paul's calendars and reminders for the phone agents, through EventKit. iOS asks once for each.
@MainActor
final class PhoneCalendar {
    private let store = EKEventStore()

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    /// Events from the start of today through `days` days ahead, in order.
    func events(days: Int) async throws -> String {
        guard try await store.requestFullAccessToEvents() else {
            throw Failure(errorDescription: "Calendar access is off for Tavern in the iPhone's Settings.")
        }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: max(1, min(days, 31)), to: start) ?? start
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else { return "Nothing on the calendar." }
        return events.prefix(40).map { event in
            let when = event.isAllDay
                ? event.startDate.formatted(.dateTime.weekday().month().day()) + " (all day)"
                : event.startDate.formatted(.dateTime.weekday().month().day().hour().minute()) + "–" + event.endDate.formatted(date: .omitted, time: .shortened)
            var line = "- \(when): \(event.title ?? "Busy")"
            if let place = event.location, !place.isEmpty { line += " at \(place)" }
            return line + " [\(event.calendar.title)]"
        }.joined(separator: "\n")
    }

    /// Reminders that aren't done, soonest due first.
    func reminders() async throws -> String {
        guard try await store.requestFullAccessToReminders() else {
            throw Failure(errorDescription: "Reminders access is off for Tavern in the iPhone's Settings.")
        }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let found: [EKReminder] = await withCheckedContinuation { done in
            store.fetchReminders(matching: predicate) { done.resume(returning: $0 ?? []) }
        }
        guard !found.isEmpty else { return "No open reminders." }
        let due = { (reminder: EKReminder) in reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) } }
        return found.sorted { (due($0) ?? .distantFuture) < (due($1) ?? .distantFuture) }.prefix(40).map { reminder in
            var line = "- \(reminder.title ?? "Untitled")"
            if let date = due(reminder) { line += " (due \(date.formatted(date: .abbreviated, time: .shortened)))" }
            return line + " [\(reminder.calendar.title)]"
        }.joined(separator: "\n")
    }

    /// Adds a reminder to the default list, due at `due` (ISO 8601 or "yyyy-MM-dd HH:mm") if given.
    func addReminder(title: String, due: String?) async throws -> String {
        guard try await store.requestFullAccessToReminders() else {
            throw Failure(errorDescription: "Reminders access is off for Tavern in the iPhone's Settings.")
        }
        guard let list = store.defaultCalendarForNewReminders() else { throw Failure(errorDescription: "There's no Reminders list to add to.") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        if let due, let date = Self.parse(due) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            reminder.addAlarm(EKAlarm(absoluteDate: date))
        }
        try store.save(reminder, commit: true)
        return "Added \"\(title)\" to \(list.title)" + (reminder.dueDateComponents == nil ? "." : ", due \(Self.parse(due ?? "")?.formatted(date: .abbreviated, time: .shortened) ?? "").")
    }

    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if let date = ISO8601DateFormatter().date(from: trimmed) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}
