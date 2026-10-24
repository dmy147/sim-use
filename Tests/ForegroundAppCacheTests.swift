// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

/// `ui` resolves the foreground app through a root-pid -> bundle id
/// cache and lists processes only when the AX root pid changes.
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
        let first = cache.resolve(rootPid: 200, listProcesses: lister.next)
        #expect(first.bundleId == "com.example.app")
        #expect(first.snapshot == AppSnapshot(appsByPid: [200: "com.example.app", 300: "com.apple.mobilesafari"]))
        for _ in 0..<5 {
            let again = cache.resolve(rootPid: 200, listProcesses: lister.next)
            #expect(again.bundleId == "com.example.app")
            #expect(again.snapshot == nil)
        }
        #expect(lister.calls == 1)
    }

    @Test("A changed root pid lists processes again and resolves SpringBoard after a crash")
    func changedRootPidRelists() {
        let cache = ForegroundAppCache(), lister = Lister([app, crashed])
        _ = cache.resolve(rootPid: 200, listProcesses: lister.next)
        let home = cache.resolve(rootPid: 100, listProcesses: lister.next)
        #expect(lister.calls == 2)
        #expect(home.bundleId == "com.apple.springboard")
        #expect(home.snapshot == AppSnapshot(appsByPid: [300: "com.apple.mobilesafari"]))
    }

    @Test("No root pid resolves to empty without listing processes")
    func noRootPid() {
        let cache = ForegroundAppCache(), lister = Lister([app])
        let result = cache.resolve(rootPid: nil, listProcesses: lister.next)
        #expect(result.bundleId == "" && result.snapshot == nil && lister.calls == 0)
    }

    @Test("A failed process list or an unresolved pid is not cached")
    func failuresAreNotCached() {
        let cache = ForegroundAppCache(), lister = Lister([nil, app, app, app])
        #expect(cache.resolve(rootPid: 200, listProcesses: lister.next).bundleId == "")
        #expect(cache.resolve(rootPid: 200, listProcesses: lister.next).bundleId == "com.example.app")
        #expect(lister.calls == 2)
        // pid 999 is not in the list (e.g. an app whose row is not registered yet): retried next time.
        #expect(cache.resolve(rootPid: 999, listProcesses: lister.next).bundleId == "")
        _ = cache.resolve(rootPid: 999, listProcesses: lister.next)
        #expect(lister.calls == 4)
    }

    @Test("Crash to home between two reads: the next ui reports the disappearance")
    func crashBetweenReadsIsReported() {
        let cache = ForegroundAppCache(), lister = Lister([app, crashed])
        let tracker = ProcessLivenessTracker(activeWindow: 120)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let read1 = cache.resolve(rootPid: 200, listProcesses: lister.next)
        #expect(DaemonDispatch.foregroundAdvisory(snapshot: read1.snapshot, tracker: tracker, now: t0) == nil)
        // Cached read on the same screen: nothing to report, nothing spawned.
        let read2 = cache.resolve(rootPid: 200, listProcesses: lister.next)
        #expect(DaemonDispatch.foregroundAdvisory(snapshot: read2.snapshot, tracker: tracker, now: t0.addingTimeInterval(1)) == nil)
        let read3 = cache.resolve(rootPid: 100, listProcesses: lister.next)
        let advisory = DaemonDispatch.foregroundAdvisory(snapshot: read3.snapshot, tracker: tracker, now: t0.addingTimeInterval(2))
        #expect(read3.bundleId == "com.apple.springboard")
        #expect(advisory?.events == [ProcessEvent(kind: .disappeared, bundleId: "com.example.app", pid: 200, confidence: .high)])
        // Still on the home screen: a cached read keeps the latched note without listing processes.
        let read4 = cache.resolve(rootPid: 100, listProcesses: lister.next)
        let level = DaemonDispatch.foregroundAdvisory(snapshot: read4.snapshot, tracker: tracker, now: t0.addingTimeInterval(3))
        #expect(level?.events == [] && level?.pending.map(\.bundleId) == ["com.example.app"])
        #expect(lister.calls == 2)
    }
}
