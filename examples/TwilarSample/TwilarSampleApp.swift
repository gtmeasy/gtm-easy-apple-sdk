import SwiftUI
import TwilarSampleFeature
import GTMEasyGrowth
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

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

  /// Run the entire cold-launch sequence in a fixed order so the first
  /// outbound event is properly enriched:
  ///   1. ATT prompt (so IDFA is present in `_ctx` if the user consents)
  ///   2. GrowthAutoInstrument.start() — fires `app.first_open` only once
  ///      per install (UserDefaults-guarded) and `app.opened` on this launch
  ///
  /// Running these in parallel races: launch events would ship without
  /// IDFA, defeating the point of having ATT in a sample.
  @MainActor
  private func launchSequence() async {
    await requestATTIfNeeded()
    await GrowthClient.autoInstrument.start()
  }

  @MainActor
  private func requestATTIfNeeded() async {
    #if canImport(AppTrackingTransparency) && os(iOS)
    if #available(iOS 14.5, *) {
      // 0.4s warmup so the prompt appears AFTER the launch screen has faded;
      // Apple recommends a small delay to avoid clobbering first-render.
      try? await Task.sleep(nanoseconds: 400_000_000)
      _ = await ATTrackingManager.requestTrackingAuthorization()
    }
    #endif
  }
}
