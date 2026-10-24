// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Routes a `DaemonRequest` to the right handler and returns the
/// response bytes ready to be written back on the wire. Kept free of
/// transport concerns so the unit-test suite (future) can drive it
/// without a real socket.
///
/// Pinned to `@MainActor` because the underlying command `execute()`
/// bodies eventually touch FBSimulatorControl, which is MainActor-only.
/// Letting dispatch run off-actor and hop at the `await execute()` call
/// appeared to deadlock first-run describe-ui under the Task-chain
/// serial model. Android verbs don't need the MainActor pin but
/// inherit it without harm.
@MainActor
public enum DaemonDispatch {
    /// Platform hook invoked when a request returns the
    /// `staleSimulator` error kind. iOSSimBackend registers a callback
    /// that drops the cached `HIDInteractor` connection for the UDID;
    /// Android daemons leave this nil — the `adb: device '…' not
    /// found` path that triggers `staleSimulator` for Android doesn't
    /// hold any cached handle that needs invalidating, and the bridge
    /// client establishes a fresh `adb forward` on every request
    /// already. The shutdown side of `staleSimulatorOutcome` is the
    /// part Android cares about (clears the zombie daemon so the next
    /// call re-spawns clean). Set this once during daemon boot, from the host
    /// executable's `Daemon.installPlatformHooks`, before the server starts
    /// accepting requests.
    public static var platformStaleCleanup: ((String) -> Void)?

    public struct Snapshot {
        public let pid: pid_t
        public let startTime: Date
        public let udid: String
        public let simUseVersion: String
        public let connectionIdentity: String?

        public init(pid: pid_t, startTime: Date, udid: String, simUseVersion: String, connectionIdentity: String? = nil) {
            self.pid = pid
            self.startTime = startTime
            self.udid = udid
            self.simUseVersion = simUseVersion
            self.connectionIdentity = connectionIdentity
        }
    }

    public struct Outcome {
        public let responseData: Data
        public let shouldStopDaemon: Bool

        public init(responseData: Data, shouldStopDaemon: Bool) {
            self.responseData = responseData
            self.shouldStopDaemon = shouldStopDaemon
        }
    }

    /// Injected by the host CLI at startup so the daemon module stays
    /// decoupled from the top-level command tree. main.swift wires this
    /// to `SimUse.parseAsRoot`.
    public static var commandParser: (@MainActor ([String]) throws -> ParsableCommand)?

    /// Platform-specific live-app probe, injected at daemon start
    /// (Android: `adb shell ps`). When nil, dispatch runs no
    /// per-command probe (issue #81); iOS wires none and `ui` reads the
    /// process list on a foreground change. A probe that
    /// returns `nil` means it could not read the process list (transient
    /// failure / timeout) — distinct from an empty device; the tracker
    /// skips such commands rather than reporting a phantom disappearance.
    ///
    /// `nonisolated(unsafe)`: the daemon serves one request at a time, so
    /// the probe and tracker below are only ever touched serially (by
    /// `@MainActor` dispatch and by the daemon-side `app-state.execute`).
    /// The annotation lets `app-state` reach the tracker without an actor
    /// hop while keeping the access genuinely single-threaded.
    nonisolated(unsafe) public static var livenessProbe: (() -> AppSnapshot?)?

    /// Process advisory produced by the command itself rather than by the
    /// per-command probe: iOS `ui` reads the process list when the AX root
    /// pid changed. Reset before every dispatched command; attached to the response when dispatch ran no
    /// probe. Daemon serialisation makes the access safe.
    nonisolated(unsafe) public static var commandProcessAdvisory: ProcessAdvisory?

    /// Cross-command crash/termination detector. The daemon serves a
    /// single device, so one tracker per process is correct. Shared so
    /// the `app-state` command can read/reset it.
    nonisolated(unsafe) public static let processTracker = ProcessLivenessTracker(activeWindow: configuredCrashWindow())

    nonisolated private static func configuredCrashWindow() -> TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["SIM_USE_CRASH_WINDOW"],
           let value = TimeInterval(raw), value > 0 {
            return value
        }
        return 120
    }

    /// Probe + evaluate the tracker for this command, unless detection is
    /// disabled, no probe is wired, or the command owns the tracker
    /// itself (`app-state`).
    private static func processAdvisory(
        for executable: any SimUseExecutableCommand
    ) -> ProcessAdvisory? {
        guard let probe = livenessProbe,
              ProcessInfo.processInfo.environment["SIM_USE_NO_CRASH_DETECT"] != "1",
              !executable.managesLivenessState
        else { return nil }
        return evaluateAdvisory(snapshot: probe(), tracker: processTracker, now: Date())
    }

    /// Advisory for a command that read the process list itself (iOS `ui`).
    /// A fresh snapshot is diffed like a probe; without one (cache hit or a
    /// failed read) only a still-latched disappearance is repeated.
    nonisolated public static func foregroundAdvisory(
        snapshot: AppSnapshot?,
        tracker: ProcessLivenessTracker,
        now: Date
    ) -> ProcessAdvisory? {
        if let snapshot { return evaluateAdvisory(snapshot: snapshot, tracker: tracker, now: now) }
        return tracker.pending.isEmpty ? nil : ProcessAdvisory(events: [], pending: Array(tracker.pending.values))
    }

    /// Pure tracker step, isolated for unit testing. A `nil` snapshot
    /// (the probe could not read the process list) is *skipped*: no diff,
    /// no events, and the tracker's baseline is left untouched, so a
    /// transient probe failure can't fake a mass "disappeared" the way an
    /// empty snapshot would (issue #81). A real snapshot is diffed and any
    /// non-empty advisory returned.
    nonisolated public static func evaluateAdvisory(
        snapshot: AppSnapshot?,
        tracker: ProcessLivenessTracker,
        now: Date
    ) -> ProcessAdvisory? {
        guard let snapshot else { return nil }
        let events = tracker.evaluate(current: snapshot, now: now)
        let advisory = ProcessAdvisory(events: events, pending: Array(tracker.pending.values))
        return advisory.isEmpty ? nil : advisory
    }

    public static func handle(_ request: DaemonRequest, snapshot: Snapshot) async -> Outcome {
        if let management = DaemonProtocol.ManagementCommand(rawValue: request.cmd) {
            return handleManagement(management, request: request, snapshot: snapshot)
        }

        if let mismatch = connectionMismatchOutcome(request, snapshot: snapshot) {
            return mismatch
        }

        guard let parser = commandParser else {
            return errorOutcome(
                id: request.id,
                error: "Daemon command parser not configured. The host CLI must set DaemonDispatch.commandParser before the daemon server accepts connections.",
                kind: .permanent
            )
        }

        let parsed: ParsableCommand
        do {
            parsed = try parser([request.cmd] + request.args)
        } catch {
            return errorOutcome(
                id: request.id,
                error: error.localizedDescription,
                kind: .permanent
            )
        }

        guard var executable = parsed as? any SimUseExecutableCommand else {
            return errorOutcome(
                id: request.id,
                error: "Command '\(request.cmd)' does not support daemon dispatch.",
                kind: .permanent
            )
        }

        commandProcessAdvisory = nil
        let advisory = processAdvisory(for: executable)
        // iOS wires no per-command probe; each command still counts as activity for the crash window.
        defer { if livenessProbe == nil { processTracker.touch(now: Date()) } }
        do {
            let data = try await executable.executeAsDaemonResponse(id: request.id, processAdvisory: advisory)
            return Outcome(responseData: data, shouldStopDaemon: false)
        } catch {
            let classifiedKind = DaemonErrorKind.classify(error)
            // A later query can fail after an earlier step changed the UI.
            // Keep its diagnostics, but do not replay an opted-out request.
            let kind: DaemonErrorKind = classifiedKind == .transientBooting && !executable.daemonAllowsTransientRetry
                ? .permanent : classifiedKind
            if kind == .staleSimulator {
                return staleSimulatorOutcome(
                    id: request.id,
                    udid: snapshot.udid,
                    underlying: error.localizedDescription
                )
            }
            return errorOutcome(
                id: request.id,
                error: error.localizedDescription,
                kind: kind,
                hint: (error as? HintProviding)?.hint
            )
        }
    }

    /// Refuse a business request whose connection identity differs from
    /// the one this daemon started under, before it is parsed or run.
    /// The client's `_ping` gate restarts such a daemon, but it cannot
    /// confirm the identity when the ping times out behind another
    /// client's slow request (the daemon serves one connection at a
    /// time). Checking the identity on the request itself closes that
    /// gap and the window between the ping and the request.
    ///
    /// The comparison is exact: a request without an identity only runs
    /// in a daemon without one (iOS targets, no provider installed).
    /// The identities are not echoed: they can carry host addresses.
    public static func connectionMismatchOutcome(_ request: DaemonRequest, snapshot: Snapshot) -> Outcome? {
        guard request.connectionIdentity != snapshot.connectionIdentity else { return nil }
        return errorOutcome(
            id: request.id,
            error: """
                sim-use daemon: the daemon for \(snapshot.udid) was started for a different \
                device connection (adb server or bridge host), so '\(request.cmd)' was not run.
                """,
            kind: .permanent,
            hint: """
                A command from the other connection is probably still running in that daemon. \
                Retry after it finishes; sim-use then restarts the daemon for this connection. \
                `sim-use daemon stop --udid \(snapshot.udid)` stops the daemon immediately, \
                including any command it is running.
                """
        )
    }

    /// Build the response for a stale-simulator detection (LINEIOS-216942):
    /// rewrite the message into something actionable, drop the cached
    /// HID handle for this UDID so it can't be reused after the next
    /// boot, and ask the server to shut down once the response goes out
    /// — the next client invocation will re-spawn a fresh daemon
    /// against whatever state the simulator is in by then.
    /// Internal (not file-private) so the unit tests can drive it
    /// directly with a synthetic underlying message instead of needing
    /// a real shut-down simulator on the host.
    public static func staleSimulatorOutcome(
        id: String?,
        udid: String,
        underlying: String
    ) -> Outcome {
        platformStaleCleanup?(udid)

        // Phrasing splits on platform: iOS daemons attach to a running
        // simulator and can be holding a stale handle when it shuts
        // down; Android daemons proxy through `adb` per request and
        // hit this path when the device serial is unknown (typo,
        // unplugged device, killed emulator). Same shutdown semantics
        // either way — give each its own first sentence so the
        // diagnostic doesn't read like an iOS-only message.
        let message: String
        let hint: String
        if PlatformRouter.looksLikeAndroid(udid) {
            message = """
                sim-use daemon: Android device \(udid) is not reachable via adb; \
                daemon is shutting down so the next call re-spawns once the \
                device is connected. Underlying error: \(underlying)
                """
            hint = """
                Verify the device is connected (`adb devices`) and the serial is \
                spelled correctly. To clean up explicitly, run \
                `sim-use daemon stop --udid \(udid)`.
                """
        } else {
            message = """
                sim-use daemon: simulator \(udid) is no longer booted; the daemon was \
                holding a stale handle. Daemon is shutting down so the next call \
                re-spawns against the current state. Underlying error: \(underlying)
                """
            hint = """
                Re-boot the simulator and retry. To clean up explicitly, run \
                `sim-use daemon stop --udid \(udid)`.
                """
        }
        let envelope = DaemonErrorResponse(
            id: id,
            error: message,
            kind: .staleSimulator,
            hint: hint
        )
        return Outcome(responseData: encode(envelope), shouldStopDaemon: true)
    }

    // MARK: - Management commands

    private static func handleManagement(
        _ command: DaemonProtocol.ManagementCommand,
        request: DaemonRequest,
        snapshot: Snapshot
    ) -> Outcome {
        switch command {
        case .ping:
            let ping = DaemonPingData(
                pid: snapshot.pid,
                uptimeSeconds: Date().timeIntervalSince(snapshot.startTime),
                protocolVersion: DaemonProtocol.version,
                simUseVersion: snapshot.simUseVersion,
                udid: snapshot.udid,
                connectionIdentity: snapshot.connectionIdentity
            )
            let envelope = DaemonSuccessResponse(id: request.id, data: ping)
            return Outcome(responseData: encode(envelope), shouldStopDaemon: false)
        case .stop:
            struct StopAck: Encodable {
                let stopping = true
            }
            let envelope = DaemonSuccessResponse(id: request.id, data: StopAck())
            return Outcome(responseData: encode(envelope), shouldStopDaemon: true)
        }
    }

    // MARK: - Encoding helpers

    private static func errorOutcome(
        id: String?,
        error: String,
        kind: DaemonErrorKind,
        hint: String? = nil
    ) -> Outcome {
        let envelope = DaemonErrorResponse(id: id, error: error, kind: kind, hint: hint)
        return Outcome(responseData: encode(envelope), shouldStopDaemon: false)
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(value) {
            return data
        }
        // Catastrophic fallback: encoding should not fail for our shapes,
        // but if it does we must still give the client a parseable answer.
        return Data("{\"ok\":false,\"error\":\"daemon: response encoding failed\",\"kind\":\"other\"}".utf8)
    }
}