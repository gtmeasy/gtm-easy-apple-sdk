import SwiftUI
import GTMEasyGrowth

/// Walks the user through the canonical paywall funnel that Twilar uses on
/// the real product:
///
///   onboarding.completed → paywall.opened → paywall.plan_selected →
///   paywall.upgrade_clicked → purchase.completed
///
/// Each stage maps to a specific Growth helper so connectors (Meta CAPI,
/// Google Ads, TikTok Events) see consistent payload shapes.
struct FunnelView: View {
  @State private var status: String = ""
  @State private var isWorking = false

  private let placement = "sample_paywall"
  private let productId = "twilar.yearly.49_99"

  var body: some View {
    NavigationStack {
      Form {
        Section("Onboarding") {
          Button("1. Onboarding completed") { run("onboarding.completed") {
            try await GrowthClient.analytics.track(
              "onboarding.completed",
              properties: ["funnel_variant": .string("default")]
            )
          } }
        }

        Section("Paywall") {
          Button("2. Paywall opened") { run("paywall.opened") {
            try await GrowthClient.analytics.trackPaywallOpened(
              placement: placement,
              variant: "annual_first",
              productIds: [productId]
            )
          } }

          Button("3. Plan selected") { run("paywall.plan_selected") {
            try await GrowthClient.analytics.trackPaywallPlanSelected(
              placement: placement,
              productId: productId,
              price: 49.99,
              currency: "USD"
            )
          } }

          Button("4. Upgrade clicked") { run("paywall.upgrade_clicked") {
            try await GrowthClient.analytics.trackPaywallUpgradeClicked(
              placement: placement,
              productId: productId,
              price: 49.99,
              currency: "USD"
            )
          } }

          Button("5b. Upgrade cancelled (StoreKit dismissed)") { run("paywall.upgrade_cancelled") {
            try await GrowthClient.analytics.trackPaywallUpgradeCancelled(
              placement: placement,
              productId: productId,
              reason: "user_cancelled_sheet"
            )
          } }
        }

        Section("Purchase") {
          Button("5a. Purchase completed (paid)") { run("purchase.completed") {
            try await GrowthClient.analytics.trackPurchaseCompleted(
              amount: 49.99,
              currency: "USD",
              productId: productId
            )
          } }

          Button("Trial started") { run("trial.started") {
            try await GrowthClient.analytics.trackTrialStarted(
              productId: productId,
              trialDurationDays: 7,
              transactionId: "tx_sample_\(Int(Date().timeIntervalSince1970))"
            )
          } }

          Button("Restore completed") { run("paywall.restore_completed") {
            try await GrowthClient.analytics.trackRestoreCompleted(
              restored: true,
              productIds: [productId]
            )
          } }
        }

        if !status.isEmpty {
          Section("Last event") {
            Text(status)
              .font(.footnote.monospaced())
              .foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("Funnel")
      .disabled(isWorking)
    }
  }

  private func run(_ label: String, _ body: @escaping () async throws -> Void) {
    Task {
      isWorking = true
      defer { isWorking = false }
      do {
        try await body()
        status = "✓ \(label)"
      } catch {
        status = "✗ \(label): \(error)"
      }
    }
  }
}
