import SwiftUI
import TavernCore

/// A heartbeat in the thread, collapsed like a tool step: "Heartbeat · 2 new · 3:10 PM". Opening
/// it shows what the host found and what the agent did about it.
struct HeartbeatRow: View {
    let run: BackgroundRun
    @ObservedObject var session: PiAgentSession
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                    Text("Heartbeat · \(run.title) · \(run.date.formatted(date: .omitted, time: .shortened))")
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").imageScale(.small)
                }
                .tavernFont(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(run.reply.map { String($0.prefix(300)) } ?? "No reply yet")
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    if !run.newItems.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(run.newItems.enumerated()), id: \.offset) { _, line in
                                Text(line).tavernFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    ForEach(run.rows) { row in
                        switch row {
                        case .message(let item): TranscriptRow(item: item)
                        case .work(let work): WorkRow(work: work)
                        case .card(_, let card): ToolCardView(card: card, session: session)
                        case .background: EmptyView()
                        }
                    }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Thread rows with each run of back-to-back heartbeats folded into one group.
enum HeartbeatRun: Identifiable {
    case row(PiThreadRow)
    case heartbeats([BackgroundRun])

    var id: String {
        switch self {
        case .row(let row): return row.id
        case .heartbeats(let runs): return "heartbeats:\(runs.first?.id ?? "")"
        }
    }

    static func grouped(_ rows: [PiThreadRow]) -> [HeartbeatRun] {
        var out: [HeartbeatRun] = []
        var pending: [BackgroundRun] = []
        func flush() {
            if pending.count == 1 { out.append(.row(.background(pending[0]))) }
            else if !pending.isEmpty { out.append(.heartbeats(pending)) }
            pending = []
        }
        for row in rows {
            if case .background(let run) = row { pending.append(run) } else { flush(); out.append(.row(row)) }
        }
        flush()
        return out
    }
}

/// Several heartbeats in a row, as one line: "12 heartbeats · 3 new · 9:10 AM–3:40 PM".
/// Opening it lists each one, newest last, still collapsed.
struct HeartbeatGroupRow: View {
    let runs: [BackgroundRun]
    @ObservedObject var session: PiAgentSession
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                    Text(title)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").imageScale(.small)
                }
                .tavernFont(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(runs) { HeartbeatRow(run: $0, session: session) }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        let found = runs.reduce(0) { $0 + $1.newItems.count }
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        let span = [runs.first, runs.last].compactMap { $0 }.map { time($0.date) }
        let when = Calendar.current.isDate(runs.first!.date, inSameDayAs: runs.last!.date) && span[0] != span[1]
            ? "\(span[0])–\(span[1])" : (runs.last.map { $0.date.formatted(date: .abbreviated, time: .shortened) } ?? "")
        return ["\(runs.count) heartbeats", found > 0 ? "\(found) new" : nil, when].compactMap { $0 }.joined(separator: " · ")
    }
}
