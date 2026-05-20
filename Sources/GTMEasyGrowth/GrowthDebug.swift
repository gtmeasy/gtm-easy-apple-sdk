import Foundation

/// Debug sink — when `GrowthAnalyticsConfiguration.debug` is true, every event
/// + identify is mirrored here BEFORE the network call. Subscribe from the
/// host app to wire a debug UI, or check `recent()` after the fact. Notifies
/// via `NotificationCenter` so any SwiftUI/UIKit view can observe live.
public actor GrowthDebugSink {
  public static let shared = GrowthDebugSink()

  public static let notificationName = Notification.Name("com.gtmeasy.growth.debug.event")

  private var buffer: [GrowthDebugEvent] = []
  private let maxBuffer = 200

  public func record(_ event: GrowthDebugEvent) {
    buffer.append(event)
    if buffer.count > maxBuffer { buffer.removeFirst(buffer.count - maxBuffer) }
    NotificationCenter.default.post(
      name: GrowthDebugSink.notificationName,
      object: nil,
      userInfo: ["event": event]
    )
    #if DEBUG
    print("[GrowthAnalytics] \(event.kind) \(event.label) \(event.properties)")
    #endif
  }

  public func recent(limit: Int = 50) -> [GrowthDebugEvent] {
    return Array(buffer.suffix(limit))
  }

  public func clear() {
    buffer.removeAll()
  }
}

public struct GrowthDebugEvent: Sendable {
  public enum Kind: String, Sendable {
    case identify
    case track
    case attribution
    case error
  }
  public let kind: Kind
  public let label: String
  public let properties: [String: GrowthJSONValue]
  public let occurredAt: Date

  public init(kind: Kind, label: String, properties: [String: GrowthJSONValue], occurredAt: Date = Date()) {
    self.kind = kind
    self.label = label
    self.properties = properties
    self.occurredAt = occurredAt
  }
}
