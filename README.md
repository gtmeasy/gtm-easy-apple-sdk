# GTM Easy Apple SDK

First-party Swift Package Manager SDK for GTM Easy growth analytics, native attribution, and ad-platform conversion APIs.

The SDK sends events to the GTM Easy ingestion API, identifies users, persists an anonymous ID, captures the first-party device identifier (IDFV), persists click IDs (fbc/fbp/gclid/wbraid/gbraid/ttclid/msclkid/twclid/igshid), provides paywall + subscription typed helpers, captures flexible onboarding surveys, drives SKAdNetwork 4.0 conversion postbacks, and collects Apple Search Ads attribution. It does not use App Tracking Transparency or the advertising identifier (IDFA), so no `NSUserTrackingUsageDescription` is required.

## What's new (v0.5.0)

- **Version alignment**: the GTM Easy SDKs (Swift / TypeScript / Kotlin) are now unified at **0.5.0** — no API changes since 0.4.x. Folds in onboarding surveys + extensible survey metadata (v0.4.1) on top of the v0.4.0 ATT/IDFA-removal privacy release.

## What's new (v0.4.1)

- **Onboarding surveys**: `analytics.submitSurvey(surveyId:responses:)` captures flexible, self-describing survey answers (single/multi choice, rating, NPS, scale, boolean, free text) with no length truncation. Build answers with the `GrowthSurveyAnswer` factories. `trackSurveyShown` / `trackSurveyStarted` power the shown→completed funnel on the dashboard.
- **Extensible survey metadata**: attach free-form `metadata` to a submission (echoed onto every answer row) or to a single answer (merged over the submission-level payload) — stored in a JSON column read with `JSONExtract` on demand, no schema migration for new fields.

## What's new (v0.4.0)

- **Removed cross-app tracking (ATT/IDFA)**: the SDK no longer links AppTrackingTransparency or AdSupport, no longer reads the advertising identifier (IDFA), and no longer prompts for tracking authorization. `GrowthDeviceIdentifiers` now collects only the first-party vendor identifier (IDFV). Apps no longer need `NSUserTrackingUsageDescription`. **Breaking:** `requestTrackingAuthorization()`, `GrowthATTStatus`, and the `idfa`/`attStatus` fields on `GrowthDeviceSnapshot` are removed — delete any calls to them.

## What's new (v0.3.0)

- **First-class identity**: `identify(userId:username:email:traits:)` accepts optional `username` and `email` as top-level fields, persisted and reused on every later `track`.
- **Logout-safe reset**: identity lives inside the `GrowthAnalytics` actor and is hydrated in its initializer, so `track`/`identify` snapshot a consistent `(userId, anonymousId)` with no `await` boundary. `reset()` rotates the anon id and clears identity atomically.
- **Identity-aware bridges**: Clarity / PostHog / Sentry / Statsig propagate `username`/`email` and clear on logout.

## What's new (v0.2.0)

- **Auto-instrumentation**: `GrowthAutoInstrument` fires `app.first_open` (once per install) + `app.opened` on every foreground.
- **Device identifiers**: `GrowthDeviceIdentifiers.shared` reads IDFA/IDFV/ATT status; `requestTrackingAuthorization()` prompts ATT. _(Removed in v0.4.0 — IDFV only, no ATT/IDFA.)_
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

## Onboarding surveys

Capture flexible onboarding-survey answers. Each answer is self-describing (it
carries its question type + optional human label), so the GTM Easy dashboard
aggregates choice breakdowns, rating histograms, NPS, and free-text samples
without any server-side survey definition. Answers are stored verbatim (no
240-char truncation) in a dedicated survey store.

```swift
// Optionally mark the survey as shown so the dashboard can compute a
// shown → completed completion rate.
try await analytics.trackSurveyShown(surveyId: "onboarding_v1", surveyName: "Onboarding")

let ack = try await analytics.submitSurvey(
  surveyId: "onboarding_v1",
  responses: [
    .singleChoice("source", "tiktok", label: "TikTok", questionText: "Where did you hear about us?"),
    .multiChoice("goals", ["focus", "limits"], labels: ["Stay focused", "Set limits"]),
    .nps("recommend", 9),
    .rating("first_impression", 5),
    .text("anything_else", "Loving it so far"),
  ],
  surveyName: "Onboarding",
  surveyVersion: "2"
)
print(ack.submissionId, ack.accepted) // idempotency key + rows persisted
```

Pass `status: .partial` to store answers without completing the survey (no
completion event fires), or `status: .dismissed` when the user closes it. Supply
your own `submissionId` to make retries idempotent. A completed or dismissed
submission also records a `survey.completed` / `survey.dismissed` lifecycle event
for the user-journey timeline and connector fan-out.

### Extensible metadata

Attach free-form `metadata` to a submission (echoed onto every answer row) or to
an individual answer (merged **over** the submission-level payload). It lands in
a dedicated JSON column read with `JSONExtract` on demand — add A/B variants,
answer timings, or any future field **without a schema migration**.

```swift
let ack = try await analytics.submitSurvey(
  surveyId: "onboarding_v1",
  responses: [
    .rating("first_impression", 5, metadata: ["ms_to_answer": .number(1200)]),
    .text("anything_else", "Loving it"),
  ],
  metadata: ["variant": .string("B"), "flow": .string("paywall_first")] // on every row
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
