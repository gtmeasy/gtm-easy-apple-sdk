# GTM Easy Apple SDK

First-party Swift Package Manager SDK for GTM Easy growth analytics, native attribution, and ad-platform conversion APIs.

The SDK sends events to the GTM Easy ingestion API, identifies users, persists an anonymous ID, captures device identifiers (IDFA/IDFV + ATT status), persists click IDs (fbc/fbp/gclid/wbraid/gbraid/ttclid/msclkid/twclid/igshid), provides paywall + subscription typed helpers, drives SKAdNetwork 4.0 conversion postbacks, and collects Apple Search Ads attribution.

## What's new (v0.2.0)

- **Auto-instrumentation**: `GrowthAutoInstrument` fires `app.first_open` (once per install) + `app.opened` on every foreground.
- **Device identifiers**: `GrowthDeviceIdentifiers.shared` reads IDFA/IDFV/ATT status; `requestTrackingAuthorization()` prompts ATT.
- **Click ID store**: `GrowthClickIdStore` persists every supported ad-platform click id with 90-day TTL, synthesizes Meta `_fbc`/`_fbp`. `analytics.captureClickIds(from: deepLinkURL)` walks query params.
- **Typed paywall events**: `analytics.trackPaywallOpened(placement:variant:productIds:)` and 7 more helpers.
- **SKAdNetwork 4.0**: `GrowthSKAN.shared.registerForAttribution()` + `updateConversion(funnel:revenue:engagementBit:lockWindow:)` with Adjust-style CV encoding.
- **Debug mirror**: `GrowthAnalyticsConfiguration(debug: true)` mirrors every event to `GrowthDebugSink` + posts a `NotificationCenter` notification per event.
- **Generated low-level client**: `GTMEasyGrowthAPI` target — typed URLSession client auto-generated from the OpenAPI spec; the high-level `GrowthAnalytics` actor wraps it.

## Installation

### Xcode

1. Open your app project in Xcode.
2. Choose `File` -> `Add Package Dependencies...`.
3. Enter:

```text
https://github.com/gtmeasy/gtm-easy-apple-sdk
```

4. Add the `GTMEasyGrowth` product to your app target.

### Package.swift

```swift
dependencies: [
  .package(url: "https://github.com/gtmeasy/gtm-easy-apple-sdk", branch: "main"),
],
targets: [
  .target(
    name: "YourApp",
    dependencies: [
      .product(name: "GTMEasyGrowth", package: "gtm-easy-apple-sdk"),
    ]
  ),
]
```

## Quick Start

Create a growth app in GTM Easy, then copy its App ID and one-time write key.

```swift
import Foundation
import GTMEasyGrowth

let analytics = GrowthAnalytics(
  configuration: .init(
    app: "<gtm-easy-app-id>",
    writeKey: "<per-app-write-key>"
  )
)

try await analytics.identify(userId: "user_123", traits: ["plan": .string("pro")])
try await analytics.trackFirstOpen()
try await analytics.trackPurchaseCompleted(amount: 9.99, currency: "USD", productId: "pro_monthly")
```

`endpoint` defaults to `https://www.gtmeasy.com`. Override it only when running
against a self-hosted GTM Easy deployment or a local development server:

```swift
let configuration = GrowthAnalyticsConfiguration(
  app: "<gtm-easy-app-id>",
  writeKey: "<per-app-write-key>",
  endpoint: URL(string: "https://your-self-hosted.example.com")!,
  environment: .development
)
```

## Identifying users

`identify` attaches a stable **userId** plus optional **username** and **email** to
the current anonymous stream. All three are first-class (not smuggled in `traits`),
persisted to `UserDefaults`, and reused automatically on later `track` calls — so a
purchase after an app relaunch still attributes to the signed-in user. On the server
these power the People dashboard and feed hashed ad-platform match keys (email is
hashed only at ad-platform egress; plaintext at rest).

```swift
try await analytics.identify(
  userId: "user_123",
  username: "john_wayne",
  email: "john@example.com",
  traits: ["plan": .string("pro")]
)
```

Pass only the fields you have; a `nil` argument leaves that field unchanged. On
logout, call `reset()` to forget the identity and rotate the anonymous id so later
events start a fresh anonymous stream instead of re-stitching onto the previous user:

```swift
await analytics.reset()
```

## Apple Search Ads Attribution

On iOS, call:

```swift
try await analytics.collectAppleSearchAdsAttribution()
```

The SDK uses `AdServices` when available and sends the attribution token only to:

```text
/api/v1/growth/attribution/apple-search-ads
```

The GTM Easy server resolves the token with Apple's attribution API and stores the returned campaign metadata, not the raw token.

## Supported Platforms

- iOS 15+
- macOS 12+

## Development

```bash
swift test
```

## License

MIT
