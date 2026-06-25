import Foundation

/// Run a `UserDefaults` mutation on the main thread.
///
/// `UserDefaults.set(_:forKey:)` / `removeObject(forKey:)` **synchronously** post
/// `UserDefaults.didChangeNotification` on the thread that performed the write. The SDK
/// persists from background actors (`GrowthAnalytics`, `GrowthAutoInstrument`,
/// `GrowthClickIdStore`), which run on the cooperative thread pool — so without this hop
/// the change notification fires on a background thread. A host app that observes defaults
/// changes to refresh SwiftUI `@Published` / `ObservableObject` state would then publish
/// off the main thread, tripping the runtime warning:
/// *"Publishing changes from background threads is not allowed; make sure to publish values
/// from the main thread … on model updates."*
///
/// Marshalling only the write — not the surrounding decision logic — keeps the SDK's
/// classification code pure and synchronous.
///
/// - On the main thread the mutation runs **inline**, so callers that read a value back
///   synchronously (unit tests, main-actor launch code) observe it immediately.
/// - Off the main thread it is dispatched with `DispatchQueue.main.async` (never `sync`, to
///   avoid blocking a cooperative-pool thread or deadlocking).
///
/// Because the off-main write lands on a later main-queue turn, any value the SDK must read
/// back **within the same session** (the anonymous id, click ids) is mirrored in actor-held
/// memory at the call site, so correctness never depends on when the write is flushed.
@inline(__always)
func growthPersistOnMain(_ mutate: @escaping () -> Void) {
    if Thread.isMainThread {
        mutate()
    } else {
        DispatchQueue.main.async(execute: mutate)
    }
}

/// Like ``growthPersistOnMain(_:)`` but **awaits** the main-thread write before returning, so
/// the value is durably stored the moment the call completes.
///
/// Use this when the SDK reads the same key back across a later call in the same session and
/// has no in-memory mirror to fall back on — notably the install/lifecycle bookkeeping in
/// `GrowthInstallState` (`markInstalledBeforeTracking()` must be visible to the next
/// `start()`) and durable identity in `GrowthAnalytics` (a fresh instance must observe a just
/// `setUserId`/`identify`-ed user). Because callers are already inside `async` actor methods,
/// hopping to the main actor adds no thread blocking and cannot deadlock.
@inline(__always)
func growthPersistOnMainAndWait(_ mutate: @escaping @MainActor () -> Void) async {
    await MainActor.run(body: mutate)
}
