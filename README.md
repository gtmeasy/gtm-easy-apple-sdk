# GTM Easy Apple SDK

First-party Swift Package Manager SDK for GTM Easy growth analytics and native attribution.

The SDK sends events to the GTM Easy ingestion API, identifies users, persists an anonymous ID, and can collect Apple Search Ads attribution tokens on iOS.

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
