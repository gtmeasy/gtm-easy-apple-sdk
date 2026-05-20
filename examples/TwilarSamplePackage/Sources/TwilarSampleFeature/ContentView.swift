import SwiftUI
import GTMEasyGrowth

/// Root of the Twilar sample app. Tab-based shell so each SDK surface area
/// gets its own playground:
///
///  1. **Funnel** — onboarding → paywall → purchase event sequence.
///  2. **Identity** — identify, set user id, anonymous id read-back.
///  3. **Click IDs** — paste a deep link / URL with utm/click params and see
///     what the SDK persists into `_ctx`.
///  4. **SKAN** — registers + advances the SKAdNetwork CV across funnel
///     stages and (optionally) revenue buckets.
///  5. **Console** — live tail of every identify/track via the debug sink.
public struct ContentView: View {
  public init() {}

  public var body: some View {
    TabView {
      FunnelView()
        .tabItem { Label("Funnel", systemImage: "arrow.right.circle") }
      IdentityView()
        .tabItem { Label("Identity", systemImage: "person.crop.circle") }
      ClickIdsView()
        .tabItem { Label("Click IDs", systemImage: "link.circle") }
      SKANView()
        .tabItem { Label("SKAN", systemImage: "antenna.radiowaves.left.and.right") }
      DebugConsoleView()
        .tabItem { Label("Console", systemImage: "text.viewfinder") }
    }
    .task {
      // First-open is idempotent — the SDK persists a flag so duplicate
      // launches don't fan out two `app.first_open` events.
      do {
        _ = try await GrowthClient.analytics.trackFirstOpen()
        _ = try await GrowthClient.analytics.trackAppOpen()
      } catch {
        // Surface to the console tab via the debug sink; production code
        // would route to Sentry / Crashlytics here.
        print("[TwilarSample] first_open / app_open failed: \(error)")
      }
    }
  }
}
