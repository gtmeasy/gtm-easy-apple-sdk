import SwiftUI
import TwilarSampleFeature
import GTMEasyGrowth

@main
struct TwilarSampleApp: App {
  init() {
    if #available(iOS 14.0, *) {
      Task { await GrowthSKAN.shared.registerForAttribution() }
    }
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .task { await launchSequence() }
        .onOpenURL { url in
          // Persist any click ids from inbound deep links + universal links.
          // Real apps would also route to the appropriate screen here.
          Task { _ = await GrowthClient.analytics.captureClickIds(from: url) }
        }
    }
  }

  /// Run the cold-launch sequence so the first outbound event is enriched.
  /// `GrowthAutoInstrument.start()` fires `app.first_open` only once per
  /// install (UserDefaults-guarded) and `app.opened` on this launch.
  ///
  /// The SDK does not use App Tracking Transparency or the advertising
  /// identifier (IDFA) — only the first-party vendor identifier (IDFV) — so
  /// there is no ATT prompt to sequence here.
  @MainActor
  private func launchSequence() async {
    await GrowthClient.autoInstrument.start()
  }
}
