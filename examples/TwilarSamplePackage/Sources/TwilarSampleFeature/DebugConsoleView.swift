import SwiftUI
import GTMEasyGrowth

/// Live tail of every identify/track that the SDK has dispatched. Powered by
/// `GrowthDebugSink` which the SDK populates whenever the configuration has
/// `debug=true`. The sink keeps the last 200 events in memory.
struct DebugConsoleView: View {
  @State private var events: [GrowthDebugEvent] = []
  @State private var refreshTicker: Date = .now

  // Poll the sink every 0.5s — the sink supports observation via
  // NotificationCenter too, but a poll is simpler for a sample UI.
  private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

  var body: some View {
    NavigationStack {
      Group {
        if events.isEmpty {
          VStack(spacing: 12) {
            Image(systemName: "text.viewfinder")
              .font(.system(size: 48))
              .foregroundStyle(.secondary)
            Text("No events yet").font(.headline)
            Text("Fire something from the Funnel or Identity tabs and it'll show up here.")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .padding(.horizontal)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          List(events.reversed(), id: \.occurredAt) { event in
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(event.kind.rawValue.uppercased())
                  .font(.caption2.weight(.bold))
                  .padding(.horizontal, 6).padding(.vertical, 2)
                  .background(.thinMaterial, in: .capsule)
                Text(event.label).font(.body.monospaced())
                Spacer()
                Text(event.occurredAt, style: .time)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              if !event.properties.isEmpty {
                Text(prettyProps(event.properties))
                  .font(.footnote.monospaced())
                  .foregroundStyle(.secondary)
                  .lineLimit(8)
              }
            }
            .padding(.vertical, 2)
          }
          .listStyle(.plain)
        }
      }
      .navigationTitle("Console")
      .toolbar {
        #if os(iOS)
        ToolbarItem(placement: .topBarTrailing) {
          Button("Clear") {
            Task {
              await GrowthDebugSink.shared.clear()
              events = []
            }
          }
        }
        #else
        ToolbarItem {
          Button("Clear") {
            Task {
              await GrowthDebugSink.shared.clear()
              events = []
            }
          }
        }
        #endif
      }
      .onReceive(timer) { _ in refreshTicker = .now }
      .task(id: refreshTicker) {
        events = await GrowthDebugSink.shared.recent(limit: 200)
      }
    }
  }

  private func prettyProps(_ props: [String: GrowthJSONValue]) -> String {
    // Sort keys for deterministic output. The sample only cares about
    // readability — production tooling would render this as a tree.
    let lines = props.keys.sorted().map { key in
      "  \(key): \(stringify(props[key]!))"
    }
    return "{\n" + lines.joined(separator: ",\n") + "\n}"
  }

  private func stringify(_ value: GrowthJSONValue) -> String {
    switch value {
    case .string(let s): return "\"\(s)\""
    case .number(let n): return "\(n)"
    case .bool(let b): return "\(b)"
    case .null: return "null"
    case .array(let xs): return "[" + xs.map(stringify).joined(separator: ", ") + "]"
    case .object(let obj):
      let inner = obj.keys.sorted().map { "\($0): \(stringify(obj[$0]!))" }.joined(separator: ", ")
      return "{ \(inner) }"
    }
  }
}
