---
name: gtm-easy-ios
description: Integrate the GTM Easy growth analytics SDK (`GTMEasyGrowth`) into an iOS / macOS Swift app. Use when (1) The user wants to install, wire up, or upgrade `@gtmeasy/growth` for Apple platforms, (2) The user mentions "GTM Easy", "growth analytics", "gtmeasy.com", "GrowthAnalytics", or "gtm-easy-apple-sdk", (3) The user wants to ship paywall funnel events, identify users, capture ad-platform click IDs (gclid/fbclid/...), or wire SKAdNetwork 4.0 from a Swift codebase, (4) The user wants Apple Search Ads attribution or App Store Server Notifications wired in.
---

# GTM Easy iOS / macOS integration

Wire `GTMEasyGrowth` (Swift Package, iOS 15+ / macOS 12+) into the host app. Covers SPM dependency, lifecycle setup, identify + track, click-id capture, paywall events, SKAdNetwork, and Apple Search Ads attribution. The SDK uses only the first-party IDFV — no ATT prompt, no IDFA.

## Repo layout reference

Canonical SDK source: <https://github.com/gtmeasy/gtm-easy-apple-sdk>.
Working sample (every public surface, 5-tab SwiftUI app): `examples/TwilarSample.xcworkspace` in that repo. When in doubt about a public API, read the corresponding file under `examples/TwilarSamplePackage/Sources/TwilarSampleFeature/`.

## 1. Add the package

Prefer **File → Add Package Dependencies…** in Xcode with URL `https://github.com/gtmeasy/gtm-easy-apple-sdk`, then add the `GTMEasyGrowth` product to the app target.

For `Package.swift` consumers:

```swift
.package(url: "https://github.com/gtmeasy/gtm-easy-apple-sdk", branch: "main"),
// ...
.product(name: "GTMEasyGrowth", package: "gtm-easy-apple-sdk"),
```

Do NOT add the `GTMEasyGrowthAPI` product unless the host app needs the low-level OpenAPI URLSession client. The high-level `GrowthAnalytics` actor is the only surface 99% of apps need.

## 2. Singleton wrapper (always do this)

Host apps must hold a single `GrowthAnalytics` instance for the process — never construct it per call. Drop this file into `Sources/.../Growth/GrowthClient.swift`:

```swift
import Foundation
import GTMEasyGrowth

enum GrowthClient {
  static let analytics: GrowthAnalytics = {
    GrowthAnalytics(
      configuration: .init(
        app: "<gtm-easy-app-id>",          // from gtmeasy.com → Settings
        writeKey: "<per-app-write-key>",   // public SDK key, safe to ship
        environment: .production           // .staging for QA
      )
    )
  }()

  static let autoInstrument = GrowthAutoInstrument(analytics: analytics)
}
```

`endpoint` defaults to `https://www.gtmeasy.com`. Override only for self-hosted GTM Easy or LAN dev.

## 3. Launch sequence

The SDK does **not** use App Tracking Transparency (ATT) or the advertising
identifier (IDFA) — it collects only the first-party vendor identifier (IDFV),
which needs no ATT prompt and no `NSUserTrackingUsageDescription`. Start
auto-instrumentation on launch:

```swift
@main
struct YourApp: App {
  init() {
    Task {
      // UserDefaults-guarded; safe to call on every launch.
      await GrowthClient.autoInstrument.start()
      // Optional: Apple Search Ads attribution token (iOS only).
      try? await GrowthClient.analytics.collectAppleSearchAdsAttribution()
    }
  }
  // ...
}
```

`GrowthAutoInstrument.start()` fires `app.first_open` (once per install, persisted in UserDefaults) and `app.opened` on every cold start. NEVER call `analytics.track("app.first_open")` manually — it bypasses the idempotency guard.

## 4. Deep-link click-id capture

Run this from `onOpenURL` / `UIApplicationDelegate` so the next event carries `gclid`/`fbclid`/`ttclid`/etc. in `_ctx`:

```swift
.onOpenURL { url in
  Task { await GrowthClient.analytics.captureClickIds(from: url) }
}
```

The store auto-synthesizes Meta `_fbc` / `_fbp` and persists each click ID for 90 days.

## 5. Identify + track

```swift
// username + email are first-class params — not smuggled in traits.
try await GrowthClient.analytics.identify(userId: "user_123", username: "john_wayne", email: "u@x.com", traits: ["plan": .string("pro")])
try await GrowthClient.analytics.track("feature.used", properties: ["feature": .string("export")])

// On logout: forget the identity and rotate the anonymous id.
await GrowthClient.analytics.reset()
```

`username` + `email` persist in `UserDefaults` and reattach to every later `track`.

Email/phone in traits are SHA-256 hashed server-side for Enhanced Matching — never hash on the client.

## 6. Paywall funnel — use the typed helpers, not raw track

Ad-platform connectors (Meta CAPI, Google Ads, TikTok Events) depend on canonical payload shapes. Hand-rolled `track("paywall.…")` payloads will drift. Use:

```swift
try await analytics.trackPaywallOpened(placement: "settings_upgrade", productIds: ["pro_yearly"])
try await analytics.trackPaywallPlanSelected(placement: "settings_upgrade", productId: "pro_yearly", price: 49.99, currency: "USD")
try await analytics.trackPaywallUpgradeClicked(placement: "settings_upgrade", productId: "pro_yearly", price: 49.99, currency: "USD")
try await analytics.trackPurchaseCompleted(amount: 49.99, currency: "USD", productId: "pro_yearly")
```

Also available: `trackPaywallUpgradeCancelled`, `trackPaywallClosed`, `trackTrialStarted`, `trackRestoreCompleted`.

## 7. SKAdNetwork 4.0

```swift
try await GrowthSKAN.shared.registerForAttribution()
try await GrowthSKAN.shared.updateConversion(funnel: .signedUp, revenue: 0, engagementBit: false, lockWindow: false)
```

The SDK encodes Adjust-style CVs and calls `SKAdNetwork.updatePostbackConversionValue` for you.

## 8. App Store Server Notifications V2

Configure the App Store Connect webhook URL to `https://<your-gtm-easy-host>/api/v1/growth/webhooks/appstore`. The server verifies the JWS chain against Apple's leaf cert and emits `subscription.renewed` / `subscription.expired` / `subscription.refunded` events keyed to the same identity as the in-app events. No client-side wiring required.

## 9. Things to NOT do

- **Don't construct `GrowthAnalytics` per call site.** It owns persistent state (mutex, userId, anon-id cache); use the singleton.
- **Don't fire `app.first_open` from your own code.** `GrowthAutoInstrument.start()` is the only correct path.
- **Don't add ATT/IDFA back in.** The SDK intentionally does not touch AppTrackingTransparency or the advertising identifier; it uses only the first-party IDFV.
- **Don't hash email/phone before passing to `identify`.** The server hashes; double-hashing breaks Enhanced Matching.
- **Don't add `GTMEasyGrowthAPI` to the app target** unless you have a concrete reason to bypass `GrowthAnalytics`.

## 10. Verifying the wire-up

1. Build the app and open the GTM Easy dashboard → **Events** for the configured `app`.
2. The first cold start should produce `app.first_open` + `app.opened`. Subsequent launches produce only `app.opened`.
3. Open a deep link with `?gclid=test` query — the next event's `_ctx.gclid` must be `test`.
4. Call `analytics.identify("user_123")` — verify the dashboard's Users view shows `user_123` linked to the device's anonymous id.

If events don't arrive: the dashboard write-key picker must match the `writeKey` in `GrowthClient.swift`. Wrong write key returns 401 silently in production; flip `environment: .staging` + `debug: true` to surface failures.
