// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(FoundationNetworking)
// URLSession / URLRequest / HTTPURLResponse live in a separate module in
// swift-corelibs-foundation; on Apple platforms this import does not exist.
import FoundationNetworking
#endif
import SimUseCore

/// High-level Android backend operations: describe-ui, devices listing,
/// `android init` bootstrap. Wraps `Adb` + `BridgeClient` and exposes a
/// surface the SimUse CLI commands consume directly.
public final class AndroidDeviceController {
    public let adb: Adb

    public init(adb: Adb = Adb()) {
        self.adb = adb
    }

    public func listDevices() throws -> [Adb.Device] {
        try adb.devices()
    }

    /// Same enumeration as `listDevices` but reshaped into the unified
    /// `Device` model that the top-level `sim-use devices` verb emits.
    /// The display name prefers `model` over `product` because that's
    /// closer to what users recognise (`Pixel 7` vs `panther`).
    ///
    /// `adb devices` already filters its output server-side, so the
    /// `onlineOnly` filter here is just a post-step convenience. We
    /// don't run a different `adb` command for it.
    public func listUnifiedDevices(onlineOnly: Bool = false) throws -> [Device] {
        let raw = try listDevices()
        let filtered = onlineOnly ? raw.filter { $0.isOnline } : raw
        return filtered.map { device in
            Device(
                udid: device.serial,
                name: device.model ?? device.product ?? device.serial,
                platform: .android,
                kind: device.isEmulator ? .emulator : .physical,
                state: device.state,
                runtime: "Android"
            )
        }
    }

    /// Return the process-shared `BridgeClient` for `serial`.
    ///
    /// In a one-shot CLI invocation this just builds a single client
    /// and tears down with the process. Inside the `sim-use daemon`
    /// process the same instance persists across requests, keeping the
    /// auth token + adb forward + URLSession warm.
    public func bridge(serial: String) -> BridgeClient {
        BridgeClientRegistry.shared(for: serial, adb: adb)
    }

    /// End-to-end describe-ui pipeline: ensure connection, fetch tree,
    /// normalize, render, and write the outline cache.
    public func describeUI(
        serial: String,
        options: AndroidOutlineRenderer.RendererOptions = .default,
        includeRaw: Bool = true
    ) throws -> DescribeUIResult {
        let client = bridge(serial: serial)
        let perf = AndroidPerf()
        _ = try client.ping()
        perf?.stage("ping")

        let visibleOnly = Self.visibleOnlyTreeReads()
        let rawBytes = try client.fetchTreeRaw(visibleOnly: visibleOnly)
        perf?.stage("fetch")
        perf?.visibleOnly = visibleOnly
        let (result, outline) = try Self.describeUI(treeBytes: rawBytes, options: options, includeRaw: includeRaw, perf: perf)

        do {
            try OutlineCache.write(outline: outline, udid: serial)
        } catch {
            // Best-effort: a cache write failure is non-fatal, but
            // log to stderr so a permissions / full-disk regression
            // is debuggable. iOS describe-ui uses the same shape
            // via `SimUseLogger`; we don't have a logger here yet,
            // so write directly to standardError.
            FileHandle.standardError.write(
                Data("warning: failed to write outline cache for \(serial): \(error.localizedDescription)\n".utf8)
            )
        }
        perf?.stage("cacheWrite")
        perf?.finish(bytes: rawBytes.count, includeRaw: includeRaw, bridge: client.lastBridgePerf)
        return result
    }

    /// Every `ui` read asks the bridge not to descend into invisible
    /// subtrees; `SIM_USE_FULL_TREE=1` (read where the read runs, i.e. the daemon's env) restores the full walk.
    static func visibleOnlyTreeReads(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["SIM_USE_FULL_TREE"] != "1"
    }

    /// Bridge tree bytes → result, without device access (split out for tests).
    static func describeUIResult(
        treeBytes: Data,
        options: AndroidOutlineRenderer.RendererOptions,
        includeRaw: Bool
    ) throws -> DescribeUIResult {
        try describeUI(treeBytes: treeBytes, options: options, includeRaw: includeRaw).result
    }

    private static func describeUI(
        treeBytes rawBytes: Data,
        options: AndroidOutlineRenderer.RendererOptions,
        includeRaw: Bool,
        perf: AndroidPerf? = nil
    ) throws -> (result: DescribeUIResult, outline: Outline) {
        let decoded = try decodeTree(rawBytes)
        guard let root = decoded.root else {
            throw BridgeError.malformedEnvelope(underlying: "Bridge returned a tree without a root element")
        }
        perf?.stage("decode")
        if let perf { perf.nodes = AndroidPerf.count(root) }

        let outline = AndroidOutlineRenderer.render(root: root, display: decoded.display, options: options)
        perf?.stage("render")

        // Timing-insensitive crash detection: if the system crash dialog
        // ("<app> keeps stopping") is on screen, surface it as a banner
        // above the outline (so the default text surface can't miss it)
        // plus a structured `crashDialog` field for `--json`. App-agnostic
        // and level-triggered by the current tree — no state, works
        // standalone. Independent of the daemon's process-liveness signal;
        // either alone is a sufficient crash hint.
        let crashDialog = AndroidCrashDialogDetector.detect(root: root)
        let outlineText: String
        if let crashDialog {
            outlineText = CrashDialogBanner.banner(for: crashDialog) + "\n" + outline.text
        } else {
            outlineText = outline.text
        }

        // Foundation avoids recursive try-each-type decoding for ordinary bridge integers.
        let rawJSON: JSONValue? = includeRaw ? try AndroidRawJSON.decode(from: rawBytes) : nil
        perf?.stage("rawDecode")

        let result = DescribeUIResult(
            platform: .android,
            raw: rawJSON,
            outline: outlineText,
            entries: outline.entries,
            lists: outline.lists,
            screen: outline.screen,
            appLabel: outline.appLabel,
            appPackage: root.package,
            crashDialog: crashDialog,
            keyboard: decoded.keyboard.map { KeyboardSignal(visible: $0.visible, imePackage: $0.imePackage) }
        )
        return (result, outline)
    }

    // MARK: - Init / bootstrap

    public struct InitOptions: Sendable {
        public var apkPath: String?
        public var packageName: String
        public var serviceClass: String
        public init(
            apkPath: String? = nil,
            packageName: String = BridgeClient.bridgePackageName,
            serviceClass: String = "com.linecorp.simuse.devicebridge.service.SimuseAccessibilityService"
        ) {
            self.apkPath = apkPath
            self.packageName = packageName
            self.serviceClass = serviceClass
        }
    }

    public struct InitReport: Sendable {
        public let serial: String
        public let bridgeVersion: String
        public let protocolVersion: Int
        public let authTokenInstalled: Bool
        public let portForward: Int
        public let bridgeHost: String
    }

    /// Runs the 6-step bridge bootstrap: install APK → register the
    /// a11y service → enable a11y globally → toggle the HTTP server →
    /// fetch the auth token → port-forward + ping.
    /// Idempotent: rerunning on an initialized device is a no-op for
    /// every step except APK install (`install -r`).
    public func initialize(serial: String, options: InitOptions = InitOptions()) throws -> InitReport {
        // Step 1: install (or reinstall) APK.
        let apkPath = try options.apkPath ?? Self.bundledAPKPath()
        guard FileManager.default.fileExists(atPath: apkPath) else {
            throw BridgeError.transport(underlying: "Bridge APK not found at \(apkPath). Build it first via `bridge/` Gradle, or pass --apk-path.", serial: nil)
        }
        _ = try adb.install(serial: serial, apkPath: apkPath, reinstall: true, grantPermissions: true)

        // Steps 2+3: register the a11y service and enable a11y globally,
        // then poll until the settings stick. AccessibilityManagerService
        // rescans installed services asynchronously after `pm install`;
        // writes made during that window reference a component AMS does
        // not yet know about, and AMS reverts them — taking
        // `accessibility_enabled` back to 0 along with the service list.
        // Without polling, the first `init` on a real device loses the
        // race and surfaces as an opaque "network connection was lost"
        // at step 6.
        try waitForAccessibilityRegistration(
            serial: serial,
            component: "\(options.packageName)/\(options.serviceClass)",
            timeout: Self.accessibilityRegistrationTimeout
        )

        // Step 4: toggle the in-process HTTP server.
        try AuthTokenFetcher.toggleSocketServer(adb: adb, serial: serial, enabled: true)

        // Step 5: fetch the auth token.
        let token = try AuthTokenFetcher.fetch(adb: adb, serial: serial)
        let tokenOK = !token.isEmpty

        // Step 6: port-forward and ping for protocol_version check.
        let client = BridgeClient(adb: adb, serial: serial)
        let ping = try client.ping()

        return InitReport(
            serial: serial,
            bridgeVersion: ping.bridgeVersion,
            protocolVersion: ping.protocolVersion,
            authTokenInstalled: tokenOK,
            portForward: BridgeClient.defaultRemotePort,
            bridgeHost: client.connection.bridgeHost
        )
    }

    /// How long `initialize` will poll for the a11y settings to stick
    /// before giving up. Real devices typically settle in under a
    /// second; we cap at 10s so a permanent block (e.g. Android 13+
    /// Restricted Settings) surfaces an actionable error instead of
    /// hanging the user.
    static let accessibilityRegistrationTimeout: TimeInterval = 10

    /// Write the a11y settings and read them back in a loop until they
    /// match the requested values, or the deadline is hit. Each
    /// iteration is ~4 adb shell roundtrips; on emulators it lands on
    /// the first try, on a slow real device 2–3 tries (~500–750 ms).
    private func waitForAccessibilityRegistration(
        serial: String,
        component: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.25
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastObserved = "uninitialized"
        repeat {
            _ = try adb.shell(serial: serial, args: [
                "settings", "put", "secure", "enabled_accessibility_services", component,
            ])
            _ = try adb.shell(serial: serial, args: [
                "settings", "put", "secure", "accessibility_enabled", "1",
            ])
            let services = try adb.shell(serial: serial, args: [
                "settings", "get", "secure", "enabled_accessibility_services",
            ]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let enabled = try adb.shell(serial: serial, args: [
                "settings", "get", "secure", "accessibility_enabled",
            ]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if services.contains(component) && enabled == "1" {
                return
            }
            lastObserved = "enabled_accessibility_services=\(services), accessibility_enabled=\(enabled)"
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        throw BridgeError.transport(underlying: """
            AccessibilityService registration never stuck after \(Int(timeout))s of polling. \
            Last observed: \(lastObserved). \
            This usually means Android's Restricted Settings is blocking ADB-installed apps \
            from being granted accessibility. Enable it manually under \
            Settings → Accessibility → sim-use device bridge, then re-run `sim-use android init`.
            """, serial: nil)
    }

    public static func bundledAPKPath() throws -> String {
        guard let url = Bundle.module.url(
            forResource: "sim-use-device-bridge",
            withExtension: "apk",
            subdirectory: "Resources"
        ) else {
            throw BridgeError.transport(underlying: "Bridge APK not found in module bundle. Build it locally via `scripts/build-bridge.sh` (requires Android SDK + JDK 17+).", serial: nil)
        }
        return url.path
    }

    // MARK: - Tree decoding

    private static func decodeTree(
        _ data: Data
    ) throws -> (root: ElementNode?, display: DisplayMetrics?, keyboard: KeyboardStateResult?) {
        let envelope = try JSONDecoder().decode(BridgeEnvelope<ElementNode>.self, from: data)
        if !envelope.isSuccess {
            throw BridgeError.applicationError(status: envelope.status, code: envelope.code, message: envelope.error)
        }
        return (envelope.result, envelope.display, envelope.keyboard)
    }
}

/// `SIM_USE_PERF=1` stage timing of the Android `ui` read, one stderr line per read.
/// Host stages are ms; `bridge=` is the bridge's own `X-Simuse-Perf` header (root/walk/secondary/keyboard/toJson/toString ms).
/// `fetch - bridge total` is transport (bridge write + adb forward + URLSession read). Off: `AndroidPerf()` returns nil.
final class AndroidPerf {
    private var last = DispatchTime.now()
    private let start = DispatchTime.now()
    private var stages: [String] = []
    var nodes = 0
    var visibleOnly = false

    init?() {
        guard ProcessInfo.processInfo.environment["SIM_USE_PERF"] == "1" else { return nil }
    }

    func stage(_ name: String) {
        let now = DispatchTime.now()
        stages.append(String(format: "%@=%.1f", name, Double(now.uptimeNanoseconds &- last.uptimeNanoseconds) / 1e6))
        last = now
    }

    func finish(bytes: Int, includeRaw: Bool, bridge: String?) {
        let total = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1e6
        let line = "[PERF] android-ui at=\(Date().ISO8601Format(.iso8601.time(includingFractionalSeconds: true))) "
            + stages.joined(separator: " ")
            + String(format: " total=%.1f", total)
            + " bytes=\(bytes) nodes=\(nodes) raw=\(includeRaw) visibleOnly=\(visibleOnly) bridge=\(bridge ?? "-")\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    static func count(_ node: ElementNode) -> Int {
        node.children.reduce(1) { $0 + count($1) }
    }
}
