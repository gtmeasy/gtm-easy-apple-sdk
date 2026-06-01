# Twilar Sample — GTM Easy Growth Apple SDK

End-to-end SwiftUI example that exercises every public surface of
`GTMEasyGrowth`:

| Tab        | Surfaces                                                              |
|------------|-----------------------------------------------------------------------|
| Funnel     | `trackPaywallOpened`, `trackPaywallPlanSelected`, `trackPaywallUpgradeClicked`, `trackPaywallUpgradeCancelled`, `trackPaywallClosed`, `trackPurchaseCompleted`, `trackTrialStarted`, `trackRestoreCompleted` |
| Identity   | `getAnonymousId`, `setUserId`, `identify` with email/phone traits     |
| Click IDs  | `captureClickIds(from:)` from deep links, `recordClickId(_:value:)`, `collectAppleSearchAdsAttribution` |
| SKAN       | `GrowthSKAN.registerForAttribution`, `updateConversion` with CV preview |
| Console    | Live tail of `GrowthDebugSink.shared` (every identify + track)        |

## Architecture

Workspace + SPM layout produced by `xcodebuildmcp project-scaffolding scaffold-ios`:

```
examples/
├── TwilarSample.xcworkspace/        # open this in Xcode
├── TwilarSample.xcodeproj/          # app shell
├── TwilarSample/                    # @main + onOpenURL
├── TwilarSamplePackage/             # all feature code lives here
│   ├── Package.swift                # depends on ../.. (the local SDK)
│   └── Sources/TwilarSampleFeature/
│       ├── ContentView.swift        # TabView shell
│       ├── GrowthClient.swift       # single shared GrowthAnalytics instance
│       ├── FunnelView.swift         # paywall + purchase funnel
│       ├── IdentityView.swift       # identify / setUserId
│       ├── ClickIdsView.swift       # deep-link capture + ASA token
│       ├── SKANView.swift           # SKAdNetwork CV encoder + register
│       └── DebugConsoleView.swift   # tail of GrowthDebugSink
├── Config/                          # xcconfig-based build settings
└── TwilarSampleUITests/             # UI smoke (Xcode-generated)
```

The Swift Package references the SDK by **local relative path** (`../..`),
so any change you make to the SDK lights up in the sample without
re-publishing.

## Run it

### Option A — Xcode

```bash
open packages/growth-swift-sdk/examples/TwilarSample.xcworkspace
```

then ⌘R against any iPhone simulator (iOS 16.0+).

### Option B — XcodeBuildMCP CLI

```bash
xcodebuildmcp simulator build-and-run \
  --workspace-path packages/growth-swift-sdk/examples/TwilarSample.xcworkspace \
  --scheme TwilarSample \
  --simulator-name "iPhone 17"
```

## Configuration

Edit `TwilarSamplePackage/Sources/TwilarSampleFeature/GrowthClient.swift`:

```swift
public static let app = "twilar"
public static let writeKey = "wk_sample_replace_me"            // ← from gtmeasy.com → Settings → Write Keys
public static let endpoint = URL(string: "http://192.168.3.241:3000")!  // LAN staging
```

Production deployments should use `https://www.gtmeasy.com` (the SDK's
default endpoint) and an environment of `.production`.

> **ATS note:** the simulator + iOS will block plaintext HTTP to the LAN
> staging IP by default. Either flip `endpoint` to `https://www.gtmeasy.com`
> or add an `NSAppTransportSecurity → NSExceptionDomains` entry for your
> staging host in a custom `Info.plist`.

## Testing the funnel end-to-end

1. Launch the app — the first-party vendor identifier (IDFV) populates
   `properties._ctx.idfv`. (No ATT prompt — the SDK does not use IDFA.)
2. **Click IDs** tab → tap *Capture click IDs* on the prefilled URL. The
   next event will include `gclid`, `fbclid`, etc. in `_ctx`.
3. **Identity** tab → fill in a user id + email, tap *Identify*. Watch the
   **Console** tab for the resulting payload.
4. **Funnel** tab → walk top-to-bottom. Each button posts to
   `/api/v1/growth/events`; the Console mirrors every fan-out.
5. **SKAN** tab → register, then bump funnel stage + revenue, tap
   *Update conversion*. The CV preview shows what gets sent to Apple.

## Troubleshooting

| Symptom                                        | Likely cause                                                                 |
|------------------------------------------------|------------------------------------------------------------------------------|
| Events show in Console but never reach backend | LAN endpoint unreachable from simulator — check the dev server is running.   |
| 401 from `/events`                             | `writeKey` placeholder — replace with one from the dashboard.                |
| `collectAppleSearchAdsAttribution` returns nil | Only valid on a real device that received an Apple Search Ads attribution.   |
