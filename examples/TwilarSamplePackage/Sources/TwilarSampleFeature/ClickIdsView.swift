import SwiftUI
import GTMEasyGrowth

/// Demonstrates the click-id capture surface. Real apps wire this into
/// `onOpenURL` (universal links + deep links) and to the Apple Search Ads
/// `attributionToken` flow at first launch.
struct ClickIdsView: View {
  @State private var deepLinkInput: String = "twilar://onboarding?gclid=demo123&fbclid=demoFB&utm_campaign=spring_sale"
  @State private var status: String = ""

  var body: some View {
    NavigationStack {
      Form {
        Section("Paste a deep link") {
          TextField("twilar://…", text: $deepLinkInput, axis: .vertical)
            .lineLimit(3, reservesSpace: true)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Button("Capture click IDs") {
            Task {
              guard let url = URL(string: deepLinkInput) else {
                status = "✗ invalid URL"
                return
              }
              let count = await GrowthClient.analytics.captureClickIds(from: url)
              status = "✓ captured \(count) click id(s) — next event will include them under properties._ctx"
            }
          }
        }

        Section("Record a specific provider") {
          Button("Record gclid = test_g_123") {
            Task {
              await GrowthClient.analytics.recordClickId(.gclid, value: "test_g_123")
              status = "✓ recorded gclid=test_g_123"
            }
          }
          Button("Record ttclid = test_tt_456") {
            Task {
              await GrowthClient.analytics.recordClickId(.ttclid, value: "test_tt_456")
              status = "✓ recorded ttclid=test_tt_456"
            }
          }
        }

        Section("Apple Search Ads") {
          Button("Fetch + submit Apple Search Ads attribution") {
            Task {
              do {
                let response = try await GrowthClient.analytics.collectAppleSearchAdsAttribution()
                if response == nil {
                  status = "ℹ no Apple Search Ads attribution token (only valid on a real device with ASA traffic)"
                } else {
                  status = "✓ Apple Search Ads attribution submitted"
                }
              } catch {
                status = "✗ ASA attribution failed: \(error)"
              }
            }
          }
        }

        if !status.isEmpty {
          Section("Last action") {
            Text(status).font(.footnote.monospaced()).foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("Click IDs")
    }
  }
}
