import Foundation

/// Snapshot of the device's language / region / timezone settings, captured via
/// Foundation only (no location permission, no ATT).
///
/// First-class ingest fields use `locale` (BCP-47) + `timezone` (IANA). A denser
/// copy is also mirrored under `properties._ctx` for JSONExtract dashboards.
public struct GrowthSystemContext: Sendable, Equatable {
  /// BCP-47 language tag, e.g. `en-US`, `zh-Hans-CN`.
  public let locale: String
  /// IANA timezone id, e.g. `America/Los_Angeles`.
  public let timezone: String
  /// ISO 3166-1 alpha-2 region from Settings (not IP geo), e.g. `US`.
  public let region: String?
  /// Primary language subtag, e.g. `en`, `zh`.
  public let language: String?
  /// Current offset from UTC in minutes (includes DST when active).
  public let utcOffsetMinutes: Int
  /// Ordered preferred languages (capped), BCP-47 where possible.
  public let preferredLanguages: [String]
  /// Calendar identifier raw value, e.g. `gregorian`.
  public let calendar: String?
  /// `metric` / `us` / `uk` when available (iOS 16+ / macOS 13+).
  public let measurementSystem: String?

  public init(
    locale: String,
    timezone: String,
    region: String? = nil,
    language: String? = nil,
    utcOffsetMinutes: Int,
    preferredLanguages: [String] = [],
    calendar: String? = nil,
    measurementSystem: String? = nil
  ) {
    self.locale = locale
    self.timezone = timezone
    self.region = region
    self.language = language
    self.utcOffsetMinutes = utcOffsetMinutes
    self.preferredLanguages = preferredLanguages
    self.calendar = calendar
    self.measurementSystem = measurementSystem
  }

  /// Capture from live Foundation state. Prefer `autoupdatingCurrent` so a
  /// mid-session language/timezone change is reflected on the next event.
  public static func capture(
    locale: Locale = .autoupdatingCurrent,
    timeZone: TimeZone = .autoupdatingCurrent,
    preferredLanguages: [String] = Locale.preferredLanguages
  ) -> GrowthSystemContext {
    GrowthSystemContext(
      locale: bcp47Identifier(for: locale),
      timezone: timeZone.identifier,
      region: regionCode(for: locale),
      language: languageCode(for: locale),
      utcOffsetMinutes: timeZone.secondsFromGMT() / 60,
      preferredLanguages: preferredLanguages.prefix(5).map { bcp47PreferredLanguage($0) },
      calendar: calendarIdentifier(for: locale),
      measurementSystem: measurementSystem(for: locale)
    )
  }

  /// Flatten into `_ctx` keys (snake_case, stable contract).
  public var asContextProperties: [String: GrowthJSONValue] {
    var out: [String: GrowthJSONValue] = [
      "locale": .string(locale),
      "timezone": .string(timezone),
      "utc_offset_min": .number(Double(utcOffsetMinutes)),
    ]
    if let region { out["region"] = .string(region) }
    if let language { out["language"] = .string(language) }
    if !preferredLanguages.isEmpty {
      out["preferred_languages"] = .array(preferredLanguages.map { .string($0) })
    }
    if let calendar { out["calendar"] = .string(calendar) }
    if let measurementSystem { out["measurement_system"] = .string(measurementSystem) }
    return out
  }

  // MARK: - Foundation helpers

  /// BCP-47 tag for a `Locale`. Strips ICU `@…` region-override suffixes and
  /// uses hyphens so Swift matches Kotlin `toLanguageTag()` / JS `navigator.language`.
  public static func bcp47Identifier(for locale: Locale) -> String {
    let raw: String
    if #available(iOS 16, macOS 13, *) {
      // Still run through the normalizer — some OS builds return mixed forms.
      raw = locale.identifier(.bcp47)
    } else {
      raw = locale.identifier
    }
    let normalized = bcp47PreferredLanguage(raw.isEmpty ? locale.identifier : raw)
    return normalized.isEmpty ? "und" : normalized
  }

  /// Normalize a preferred-language string (may already be BCP-47 or ICU).
  public static func bcp47PreferredLanguage(_ raw: String) -> String {
    let base = raw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true)
      .first
      .map(String.init) ?? raw
    return base.replacingOccurrences(of: "_", with: "-")
  }

  private static func regionCode(for locale: Locale) -> String? {
    if #available(iOS 16, macOS 13, *) {
      return locale.region?.identifier
    }
    return locale.regionCode
  }

  private static func languageCode(for locale: Locale) -> String? {
    if #available(iOS 16, macOS 13, *) {
      return locale.language.languageCode?.identifier
    }
    return locale.languageCode
  }

  private static func calendarIdentifier(for locale: Locale) -> String? {
    // `Calendar.Identifier` has no stable string API pre-iOS 16; use description
    // of the raw value for a compact, human-readable tag.
    String(describing: locale.calendar.identifier)
  }

  private static func measurementSystem(for locale: Locale) -> String? {
    if #available(iOS 16, macOS 13, *) {
      switch locale.measurementSystem {
      case .metric: return "metric"
      case .us: return "us"
      case .uk: return "uk"
      default: return String(describing: locale.measurementSystem)
      }
    }
    return nil
  }
}

/// Injectable seam so unit tests don't depend on the host machine's locale/tz.
public protocol GrowthSystemContextProviding: Sendable {
  func current() -> GrowthSystemContext
}

/// Default provider — reads live Foundation settings on every call.
public struct LiveGrowthSystemContextProvider: GrowthSystemContextProviding {
  public static let shared = LiveGrowthSystemContextProvider()
  public init() {}
  public func current() -> GrowthSystemContext { .capture() }
}

/// Fixed snapshot for tests.
public struct FixedGrowthSystemContextProvider: GrowthSystemContextProviding {
  public let value: GrowthSystemContext
  public init(_ value: GrowthSystemContext) { self.value = value }
  public func current() -> GrowthSystemContext { value }
}
