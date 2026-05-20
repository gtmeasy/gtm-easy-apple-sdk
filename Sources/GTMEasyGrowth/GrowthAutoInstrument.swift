import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Fires `app.first_open` exactly once per install and `app.opened` on every
/// foreground transition. Host app calls `start()` from
/// `application(_:didFinishLaunchingWithOptions:)`; everything else is
/// notification-driven so no extra integration is needed.
public actor GrowthAutoInstrument {
  private let analytics: GrowthAnalytics
  private let defaults: UserDefaults
  private let firstOpenKey = "gtm_easy_growth_first_open_fired"
  private let installAtKey = "gtm_easy_growth_install_at"
  private var observers: [NSObjectProtocol] = []

  public init(analytics: GrowthAnalytics, defaults: UserDefaults = .standard) {
    self.analytics = analytics
    self.defaults = defaults
  }

  public func start() async {
    await fireFirstOpenIfNeeded()
    await fireAppOpen()
    observeForegroundTransitions()
  }

  public func stop() {
    for token in observers { NotificationCenter.default.removeObserver(token) }
    observers.removeAll()
  }

  private func fireFirstOpenIfNeeded() async {
    if defaults.bool(forKey: firstOpenKey) { return }
    defaults.set(true, forKey: firstOpenKey)
    defaults.set(Date().timeIntervalSince1970, forKey: installAtKey)
    do {
      _ = try await analytics.trackFirstOpen()
    } catch {
      // Auto-instrumentation must never crash the host app.
    }
  }

  private func fireAppOpen() async {
    do {
      _ = try await analytics.trackAppOpen()
    } catch {
      // Swallow.
    }
  }

  private func observeForegroundTransitions() {
    #if canImport(UIKit) && os(iOS)
    let token = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      Task { await self.fireAppOpen() }
    }
    observers.append(token)
    #endif
  }

  /// Timestamp of the first launch we observed for this install. Useful for
  /// SKAN engagement windows and retention math without server roundtrips.
  public var installAt: Date? {
    let ts = defaults.double(forKey: installAtKey)
    return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
  }
}
