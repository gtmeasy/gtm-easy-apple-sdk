import SwiftUI
import TwilarSampleFeature
import GTMEasyGrowth
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

@main
struct TwilarSampleApp: App {
  // Register SKAdNetwork as early as possible. The actor is process-shared.
  init() {
    if #available(iOS 14.0, *) {
      Task { await GrowthSKAN.shared.registerForAttribution() }
    }
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .task {
          // Ask for App Tracking Transparency on first launch. Production apps
          // should defer this until they have UI context for the user, but
          // the sample is opinionated about showing the full flow.
          await requestATTIfNeeded()
        }
        .onOpenURL { url in
          // Persist any click ids from inbound deep links + universal links.
          // Real apps would also route to the appropriate screen here.
          Task { _ = await GrowthClient.analytics.captureClickIds(from: url) }
        }
    }
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
