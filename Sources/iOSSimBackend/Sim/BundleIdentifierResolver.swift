// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Resolves the `CFBundleIdentifier` of a simulator's frontmost app.
///
/// Strategy: read the AX-root element's `pid` (every AX node carries
/// `pid` per the FBSimulatorControl serializer), then look the pid up
/// against `xcrun simctl spawn <udid> launchctl list`. Each row is
/// `<pid> <status> UIKitApplication:<bundleId>[xxxx][xxxx]` for hosted
/// apps; we extract the bundle id from the label.
///
/// Returns empty string when the AX root has no pid, when simctl is
/// unreachable, or when the pid isn't a UIKitApplication. `describe-ui`
/// treats appPackage as hint-grade, not authoritative — failing to
/// resolve is non-fatal.
public enum BundleIdentifierResolver {

    /// The daemon's foreground cache (one device per daemon; requests are served serially).
    nonisolated(unsafe) public static let foregroundCache = ForegroundAppCache()

    /// `launchctl list` output, or nil when it could not be read.
    public static func launchctlList(udid: String) -> String? {
        try? runLaunchctlList(udid: udid)
    }

    /// Parser exposed for tests. Returns the bundle id when the input
    /// contains a `UIKitApplication:<bundleId>[…]` row for `pid`.
    ///
    /// The `label` column is conventionally a single whitespace-free
    /// token (launchctl labels never contain spaces — the system
    /// uses dots / hyphens / colons). The `count >= 3` guard
    /// already ensures `columns.last` is non-nil, but `if let`
    /// keeps the destructure honest without the force-unwrap.
    public static func parse(launchctlOutput: String, pid: Int) -> String? {
        for rawLine in launchctlOutput.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("PID") { continue }
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 3 else { continue }
            guard let rowPid = Int(columns[0]), rowPid == pid else { continue }
            guard let last = columns.last else { continue }
            return bundleId(fromLabel: String(last))
        }
        return nil
    }

    /// Parses every *running* `UIKitApplication:` row into a
    /// `[pid: bundleId]` map for liveness tracking. Rows without a
    /// numeric pid (`-`, i.e. installed-but-not-running) and
    /// non-`UIKitApplication` labels (system daemons, including
    /// SpringBoard's daemon label) are excluded, so the map contains
    /// only live hosted apps. Pure; exposed for tests and for building
    /// an `AppSnapshot`.
    public static func appsByPid(launchctlOutput: String) -> [Int: String] {
        var map: [Int: String] = [:]
        for rawLine in launchctlOutput.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("PID") { continue }
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 3,
                  let pid = Int(columns[0]),
                  let last = columns.last,
                  let bundleId = bundleId(fromLabel: String(last))
            else { continue }
            map[pid] = bundleId
        }
        return map
    }

    /// Build an `AppSnapshot` of the simulator's live hosted apps.
    /// Returns `nil` when the `launchctl` spawn fails or times out — a
    /// probe failure is "unknown", distinct from a genuinely empty device.
    /// The liveness tracker treats `nil` as "skip this command" rather
    /// than "everything died", so a transient simctl hiccup can't fake a
    /// mass disappearance (issue #81).
    public static func appSnapshot(udid: String) -> AppSnapshot? {
        guard let output = try? runLaunchctlList(udid: udid) else {
            return nil
        }
        return AppSnapshot(appsByPid: appsByPid(launchctlOutput: output))
    }

    /// SpringBoard runs under the plain daemon label `com.apple.SpringBoard`
    /// (not `UIKitApplication:`), yet it IS the foreground after a
    /// foreground app crashes to the home screen. Map it to its canonical
    /// lowercase bundle id so `ForegroundLabel` can render "SpringBoard"
    /// instead of an empty header (issue #81).
    static let springBoardDaemonLabel = "com.apple.SpringBoard"
    static let springBoardBundleId = "com.apple.springboard"

    /// Foreground-resolution variant of `bundleId(fromLabel:)`: also
    /// recognises SpringBoard's daemon label. Used by `resolve` (header
    /// reconciliation) but NOT by `appsByPid` (liveness), so SpringBoard
    /// is never tracked as an "app under test".
    public static func foregroundBundleId(fromLabel label: String) -> String? {
        if let app = bundleId(fromLabel: label) { return app }
        if label == springBoardDaemonLabel { return springBoardBundleId }
        return nil
    }

    /// Like `parse`, but resolves SpringBoard too (see `foregroundBundleId`).
    public static func parseForeground(launchctlOutput: String, pid: Int) -> String? {
        for rawLine in launchctlOutput.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("PID") { continue }
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 3, let rowPid = Int(columns[0]), rowPid == pid else { continue }
            guard let last = columns.last else { continue }
            return foregroundBundleId(fromLabel: String(last))
        }
        return nil
    }

    /// Pulls `com.example.app` out of `UIKitApplication:com.example.app[1234][...]`.
    /// Returns nil for non-UIKitApplication labels (e.g. system daemons).
    public static func bundleId(fromLabel label: String) -> String? {
        let prefix = "UIKitApplication:"
        guard label.hasPrefix(prefix) else { return nil }
        let trimmed = label.dropFirst(prefix.count)
        if let bracket = trimmed.firstIndex(of: "[") {
            return String(trimmed[..<bracket])
        }
        return String(trimmed)
    }

    // MARK: - simctl bridge

    /// `simctl spawn` can wedge if the target simulator is
    /// mid-boot / mid-shutdown — `waitUntilExit()` then blocks the
    /// describe-ui path indefinitely. The pid-resolution itself is
    /// strictly best-effort (`describe-ui` treats appPackage as a
    /// hint), so cap the spawn at 5 s and treat a timeout as
    /// "couldn't resolve" rather than letting it hang the whole
    /// command.
    private static let launchctlTimeout: TimeInterval = 5

    private static func runLaunchctlList(udid: String) throws -> String {
        try runCapturing(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "spawn", udid, "launchctl", "list"],
            timeout: launchctlTimeout
        )
    }

    /// Runs a child and returns its stdout. Internal for tests; `makePipe` lets a test observe the pipes.
    static func runCapturing(
        executable: URL, arguments: [String], timeout: TimeInterval, makePipe: () -> Pipe = { Pipe() }
    ) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutPipe = makePipe()
        let stderrPipe = makePipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Close our read ends on every path, including the timeout below: an unclosed Pipe leaks two
        // descriptors per call, and in the long-lived daemon that ended every later spawn.
        defer {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                // Give the child a brief settle so the FDs reap
                // cleanly. Mirrors `Adb.run`'s timeout pattern.
                let killDeadline = Date().addingTimeInterval(0.5)
                while process.isRunning, Date() < killDeadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                throw NSError(
                    domain: "BundleIdentifierResolver",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "simctl spawn timed out after \(timeout)s"]
                )
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        // The child has exited, so this returns at once. It runs the
        // termination block Process queued on this thread's run loop; until
        // that runs, the block keeps the Process and both Pipes alive, and in
        // the daemon it later ran outside any autorelease pool, so every call
        // leaked both Pipes. Not called on the timeout path, where a child
        // that ignores terminate() would block here; `defer` closes the read
        // ends there.
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "BundleIdentifierResolver", code: Int(process.terminationStatus))
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Root pid -> foreground bundle id of the last process-list read.
/// The AX root pid changes whenever the foreground app changes, crashes to SpringBoard or relaunches,
/// so a read with the same root pid reuses the bundle id and spawns no `launchctl list` (~270 ms).
/// Empty results and failed reads are not cached.
public final class ForegroundAppCache {
    private var entry: (pid: Int, bundleId: String)?

    public init() {}

    /// `snapshot` is the fresh process list when one was read (for the crash tracker), nil on a cache
    /// hit, without a root pid, or when the list could not be read.
    public func resolve(rootPid: Int?, listProcesses: () -> String?) -> (bundleId: String, snapshot: AppSnapshot?) {
        guard let pid = rootPid, pid > 0 else { return ("", nil) }
        if let entry, entry.pid == pid { return (entry.bundleId, nil) }
        guard let output = listProcesses() else { return ("", nil) }
        let bundleId = BundleIdentifierResolver.parseForeground(launchctlOutput: output, pid: pid) ?? ""
        entry = bundleId.isEmpty ? nil : (pid, bundleId)
        return (bundleId, AppSnapshot(appsByPid: BundleIdentifierResolver.appsByPid(launchctlOutput: output)))
    }
}
