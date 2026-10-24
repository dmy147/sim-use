// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

/// `ui` resolves the foreground app through a (device, root pid) ->
/// bundle id cache and lists processes only when the AX root pid changes.
@Suite("ForegroundAppCache — process list only on a root-pid change")
struct ForegroundAppCacheTests {
    private let app = """
    PID\tStatus\tLabel
    100\t0\tcom.apple.SpringBoard
    200\t0\tUIKitApplication:com.example.app[1][a]
    300\t0\tUIKitApplication:com.apple.mobilesafari[2][b]
    """
    /// The app crashed to the home screen: its row is gone, SpringBoard is the AX root.
    private let crashed = """
    PID\tStatus\tLabel
    100\t0\tcom.apple.SpringBoard
    -\t0\tUIKitApplication:com.example.app[1][a]
    300\t0\tUIKitApplication:com.apple.mobilesafari[2][b]
    """

    private final class Lister {
        var outputs: [String?]
        var calls = 0
        init(_ outputs: [String?]) { self.outputs = outputs }
        func next() -> String? { calls += 1; return outputs.isEmpty ? nil : outputs.removeFirst() }
    }

    @Test("The same root pid reuses the cached bundle id without listing processes")
    func sameRootPidIsCached() {
        let cache = ForegroundAppCache(), lister = Lister([app])
        for _ in 0..<5 {
            #expect(cache.resolve(udid: "A", rootPid: 200, listProcesses: lister.next) == "com.example.app")
        }
        #expect(lister.calls == 1)
    }

    @Test("A changed root pid lists processes again and resolves SpringBoard after a crash")
    func changedRootPidRelists() {
        let cache = ForegroundAppCache(), lister = Lister([app, crashed])
        _ = cache.resolve(udid: "A", rootPid: 200, listProcesses: lister.next)
        #expect(cache.resolve(udid: "A", rootPid: 100, listProcesses: lister.next) == "com.apple.springboard")
        #expect(lister.calls == 2)
    }

    @Test("Another device with the same root pid lists processes again")
    func otherDeviceRelists() {
        let cache = ForegroundAppCache(), lister = Lister([app, app])
        _ = cache.resolve(udid: "A", rootPid: 200, listProcesses: lister.next)
        _ = cache.resolve(udid: "B", rootPid: 200, listProcesses: lister.next)
        #expect(lister.calls == 2)
    }

    @Test("No root pid resolves to empty without listing processes")
    func noRootPid() {
        let cache = ForegroundAppCache(), lister = Lister([app])
        #expect(cache.resolve(udid: "A", rootPid: nil, listProcesses: lister.next) == "")
        #expect(lister.calls == 0)
    }

    @Test("A failed process list or an unresolved pid is not cached")
    func failuresAreNotCached() {
        let cache = ForegroundAppCache(), lister = Lister([nil, app, app, app])
        #expect(cache.resolve(udid: "A", rootPid: 200, listProcesses: lister.next) == "")
        #expect(cache.resolve(udid: "A", rootPid: 200, listProcesses: lister.next) == "com.example.app")
        #expect(lister.calls == 2)
        // pid 999 is not in the list (e.g. an app whose row is not registered yet): retried next time.
        #expect(cache.resolve(udid: "A", rootPid: 999, listProcesses: lister.next) == "")
        _ = cache.resolve(udid: "A", rootPid: 999, listProcesses: lister.next)
        #expect(lister.calls == 4)
    }

    @Test("resolve without a usable liveness snapshot answers from the cache (no launchctl)")
    func resolverFallsBackToCache() throws {
        let cache = ForegroundAppCache()
        _ = cache.resolve(udid: "UNREACHABLE-UDID", rootPid: 200) { app }
        let root = try JSONDecoder().decode(AccessibilityElement.self, from: Data(#"{"pid":200}"#.utf8))
        // No snapshot (detection disabled) and a snapshot without the root pid both hit the cache.
        for snapshot in [nil, AppSnapshot(appsByPid: [300: "com.apple.mobilesafari"])] {
            let resolved = BundleIdentifierResolver.resolve(
                udid: "UNREACHABLE-UDID", rootElement: root, cachedSnapshot: snapshot, foregroundCache: cache
            )
            #expect(resolved == "com.example.app")
        }
    }
}
