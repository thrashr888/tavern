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
