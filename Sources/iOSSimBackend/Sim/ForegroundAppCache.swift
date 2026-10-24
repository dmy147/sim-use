// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Foreground bundle id of the last process-list read, keyed by device
/// and accessibility root pid.
///
/// The AX root pid changes whenever the foreground app changes, crashes
/// to SpringBoard or relaunches, so a `ui` read with the same root pid
/// reuses the bundle id instead of spawning `launchctl list` again
/// (~270 ms on a warm daemon). Empty results and failed reads are not
/// cached, so they are retried on the next read.
public final class ForegroundAppCache: @unchecked Sendable {
    /// Process-wide instance. In the daemon it lives across commands;
    /// a one-shot CLI process starts empty.
    public static let shared = ForegroundAppCache()

    private let lock = NSLock()
    private var entry: (udid: String, pid: Int, bundleId: String)?

    public init() {}

    public func resolve(udid: String, rootPid: Int?, listProcesses: () -> String?) -> String {
        guard let pid = rootPid, pid > 0 else { return "" }
        lock.lock()
        let cached = entry
        lock.unlock()
        if let cached, cached.udid == udid, cached.pid == pid { return cached.bundleId }
        guard let output = listProcesses() else { return "" }
        let bundleId = BundleIdentifierResolver.parseForeground(launchctlOutput: output, pid: pid) ?? ""
        lock.lock()
        entry = bundleId.isEmpty ? nil : (udid, pid, bundleId)
        lock.unlock()
        return bundleId
    }
}
