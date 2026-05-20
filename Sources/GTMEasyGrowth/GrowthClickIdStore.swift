import Foundation

/// Persisted click identifiers captured from deep links, ad clicks, install
/// referrers, or the launching SafariViewController URL. Stored in
/// UserDefaults keyed by provider so the host app can capture once and reuse
/// across every subsequent event — required because Meta/TikTok CAPI dedupe
/// keys depend on these.
public actor GrowthClickIdStore {
  public static let shared = GrowthClickIdStore()

  private let defaults: UserDefaults
  private let prefix = "gtm_easy_growth_click_id_"

  /// 90 days matches Meta's `_fbc` cookie semantics and TikTok's `ttclid`
  /// retention. Click ids older than this should be considered stale.
  public static let defaultTTL: TimeInterval = 60 * 60 * 24 * 90

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Records a click id for a provider. Skip-stores empty strings.
  public func record(_ provider: GrowthClickProvider, value: String, at: Date = Date()) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let payload: [String: Any] = [
      "value": trimmed,
      "ts": at.timeIntervalSince1970,
    ]
    defaults.set(payload, forKey: key(provider))
  }

  /// Returns the current value if present and not stale.
  public func current(_ provider: GrowthClickProvider, ttl: TimeInterval = defaultTTL, now: Date = Date()) -> String? {
    guard let payload = defaults.dictionary(forKey: key(provider)) else { return nil }
    guard let value = payload["value"] as? String, !value.isEmpty else { return nil }
    if let ts = payload["ts"] as? TimeInterval {
      if now.timeIntervalSince1970 - ts > ttl { return nil }
    }
    return value
  }

  public func clear(_ provider: GrowthClickProvider) {
    defaults.removeObject(forKey: key(provider))
  }

  /// Snapshot of all known click ids, ready to merge into an event payload.
  public func snapshot(now: Date = Date()) -> [String: GrowthJSONValue] {
    var out: [String: GrowthJSONValue] = [:]
    for provider in GrowthClickProvider.allCases {
      if let value = current(provider, now: now) {
        out[provider.eventKey] = .string(value)
      }
    }
    // Meta also needs `_fbp` (browser-side persistent id). On iOS we
    // synthesize a stable per-install equivalent — see ensureFbp().
    if let fbp = ensureFbp() {
      out["fbp"] = .string(fbp)
    }
    return out
  }

  /// Builds Meta's `_fbc` value when we have an `fbclid`. Format spec:
  /// `fb.1.{timestamp_ms}.{fbclid}` — Meta requires this exact shape.
  public func ensureFbc(from fbclid: String, at: Date = Date()) -> String? {
    guard !fbclid.isEmpty else { return nil }
    let ms = Int64(at.timeIntervalSince1970 * 1000)
    let fbc = "fb.1.\(ms).\(fbclid)"
    record(.fbc, value: fbc, at: at)
    return fbc
  }

  /// Persistent `_fbp` per Meta spec: `fb.1.{ts_ms}.{random_int}`. Once set
  /// it is never rotated within the install; only an explicit `clear` resets.
  public func ensureFbp(now: Date = Date()) -> String? {
    if let existing = current(.fbp, ttl: .infinity, now: now) { return existing }
    let ms = Int64(now.timeIntervalSince1970 * 1000)
    // Meta accepts any int — use 10 random digits to match their cookie shape.
    var rng = SystemRandomNumberGenerator()
    let rand = UInt32.random(in: 1_000_000_000...UInt32.max, using: &rng)
    let value = "fb.1.\(ms).\(rand)"
    record(.fbp, value: value, at: now)
    return value
  }

  private func key(_ provider: GrowthClickProvider) -> String {
    "\(prefix)\(provider.rawValue)"
  }
}

public enum GrowthClickProvider: String, CaseIterable, Sendable {
  case fbc            // Facebook click — derived from fbclid
  case fbp            // Facebook browser id — synthesized per install
  case fbclid         // Raw Meta click id from deep link
  case gclid          // Google Ads click id
  case wbraid         // Google Web-to-app click id
  case gbraid         // Google App-to-app click id
  case ttclid         // TikTok click id
  case igshid         // Instagram share id
  case msclkid        // Microsoft Ads click id
  case twclid         // Twitter/X Ads click id

  var eventKey: String {
    switch self {
    case .fbc: return "fbc"
    case .fbp: return "fbp"
    case .fbclid: return "fbclid"
    case .gclid: return "gclid"
    case .wbraid: return "wbraid"
    case .gbraid: return "gbraid"
    case .ttclid: return "ttclid"
    case .igshid: return "igshid"
    case .msclkid: return "msclkid"
    case .twclid: return "twclid"
    }
  }
}

private extension TimeInterval {
  static let infinity: TimeInterval = .greatestFiniteMagnitude
}
