import SwiftUI
import GTMEasyGrowth

/// SKAdNetwork 4.0 helper view. Demonstrates the 6-bit CV encoding documented
/// on `GrowthSKANConversionValue.encode`:
///   `(revenueBucket << 3) | (funnelStage << 1) | engagementBit`.
@available(iOS 14.0, *)
struct SKANView: View {
  @State private var funnel: GrowthSKANFunnelStage = .install
  @State private var revenue: Double = 0
  @State private var engagement: Bool = false
  @State private var lockWindow: Bool = false
  @State private var status: String = ""

  var body: some View {
    NavigationStack {
      Form {
        Section("Funnel stage") {
          Picker("stage", selection: $funnel) {
            Text("install").tag(GrowthSKANFunnelStage.install)
            Text("onboarded").tag(GrowthSKANFunnelStage.onboarded)
            Text("trial").tag(GrowthSKANFunnelStage.trial)
            Text("purchase").tag(GrowthSKANFunnelStage.purchase)
          }
          .pickerStyle(.segmented)
        }

        Section("Revenue (USD)") {
          Stepper(value: $revenue, in: 0...500, step: 5) {
            Text("$\(String(format: "%.0f", revenue))")
          }
          let preview = GrowthSKANConversionValue.encode(
            funnel: funnel, revenue: revenue, engagementBit: engagement
          )
          Text("→ fine=\(preview.fineValue), coarse=\(preview.coarseValue.rawValue)")
            .font(.footnote.monospaced())
            .foregroundStyle(.secondary)
        }

        Section("Flags") {
          Toggle("Engagement bit", isOn: $engagement)
          Toggle("Lock window early", isOn: $lockWindow)
            .help("Ends the current SKAN postback window immediately. Useful when you've already learned everything you can about this install.")
        }

        Section {
          Button("Register for attribution") {
            Task {
              await GrowthClient.skan.registerForAttribution()
              status = "✓ registered"
            }
          }
          Button("Update conversion") {
            Task {
              await GrowthClient.skan.updateConversion(
                funnel: funnel,
                revenue: revenue,
                engagementBit: engagement,
                lockWindow: lockWindow
              )
              status = "✓ updateConversion(funnel=\(funnel.rawValue), revenue=\(revenue), engagement=\(engagement), lock=\(lockWindow))"
            }
          }
        }

        if !status.isEmpty {
          Section("Last action") {
            Text(status).font(.footnote.monospaced()).foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("SKAdNetwork")
    }
  }
}
