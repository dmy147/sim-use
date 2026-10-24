// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AndroidBackend

/// A persisted bridge session (forwarded port + bearer token) is only
/// valid for the adb server that created the forward. These tests pin
/// that a session is never replayed against a different connection —
/// switched adb server, a cache written before sessions recorded their
/// connection, or a cached port now answered by something other than
/// our forward — so the token is never sent to an unrelated listener.
///
/// `adb` is a recording shell script; HTTP goes through a URLProtocol
/// that answers every request like a live listener would and records
/// where it went and which token it carried.
final class BridgeConnectionScopingTests: XCTestCase {
    private let serial = "emulator-5554"
    private let serverA = ["ADB_SERVER_SOCKET": "tcp:192.0.2.10:5037"]
    private let serverB = ["ADB_SERVER_SOCKET": "tcp:192.0.2.20:5037"]

    private var root: URL!
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var adbLog: URL { root.appendingPathComponent("adb.log") }
    private var forwardList: URL { root.appendingPathComponent("forwards.txt") }
    private var failForwardList = false

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-bridge-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        RecordingBridgeProtocol.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Regressions

    /// Session written against server A, client now pointed at server B:
    /// the cached port and token must not be used, even though a
    /// listener answers on B at A's old port.
    func testSwitchingAdbServerRecreatesForwardAndToken() throws {
        persistSession(token: "token-A", localPort: 18080, environment: serverA)

        try makeClient(environment: serverB).pressKey(3)

        assertNothingSent(toPort: 18080, withToken: "token-A")
        XCTAssertFalse(adbCalls().contains { $0.contains("forward --remove") })
        assertAllRequests(host: "192.0.2.20", port: 18081, authorizedWith: "token-B")
        XCTAssertTrue(adbCalls().contains { $0.contains("forward tcp:0 tcp:8080") }, "a new forward must be created")
        XCTAssertTrue(adbCalls().contains { $0.contains("content query") }, "the token must be fetched again")
    }

    /// A `bridge.json` from before sessions recorded their connection
    /// cannot prove which adb server it belongs to.
    func testLegacySessionWithoutConnectionIsNotReused() throws {
        let legacy = #"{"token":"token-A","localPort":18080,"remotePort":8080,"writtenAt":"2026-09-01T00:00:00Z"}"#
        let file = BridgeSessionStore.file(for: serial, home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: file)

        try makeClient(environment: [:]).pressKey(3)

        assertNothingSent(toPort: 18080, withToken: "token-A")
        assertAllRequests(host: "127.0.0.1", port: 18081, authorizedWith: "token-B")
    }

    /// Same connection, but the cached port is no longer our forward
    /// (it is answered by an unrelated listener): responding is not
    /// proof of identity, so the forward and token are recreated.
    func testUnrelatedListenerOnCachedPortIsNotTrusted() throws {
        persistSession(token: "token-A", localPort: 18080, environment: [:])
        try "other-device tcp:18080 tcp:8080\n".write(to: forwardList, atomically: true, encoding: .utf8)

        try makeClient(environment: [:]).pressKey(3)

        assertNothingSent(toPort: 18080, withToken: "token-A")
        assertAllRequests(host: "127.0.0.1", port: 18081, authorizedWith: "token-B")
    }

    /// The fast path survives: same connection and the forward is still
    /// registered for this serial, so no adb bootstrap is repeated.
    func testMatchingSessionWithLiveForwardIsReused() throws {
        persistSession(token: "token-A", localPort: 18080, environment: serverA)
        try "\(serial) tcp:18080 tcp:8080\n".write(to: forwardList, atomically: true, encoding: .utf8)

        try makeClient(environment: serverA).pressKey(3)

        assertAllRequests(host: "192.0.2.10", port: 18080, authorizedWith: "token-A")
        XCTAssertFalse(adbCalls().contains { $0.contains("forward tcp:0") }, "no new forward expected")
        XCTAssertFalse(adbCalls().contains { $0.contains("content query") }, "no token fetch expected")
    }

    /// The rewritten session records the connection it was created for.
    func testRecreatedSessionRecordsItsConnection() throws {
        persistSession(token: "token-A", localPort: 18080, environment: serverA)

        try makeClient(environment: serverB).pressKey(3)

        let stored = try XCTUnwrap(BridgeSessionStore.read(udid: serial, home: home))
        XCTAssertEqual(stored.localPort, 18081)
        XCTAssertEqual(stored.token, "token-B")
        XCTAssertEqual(stored.connection, BridgeConnection(environment: serverB).identity)
        XCTAssertEqual(stored.adbServer, BridgeConnection(environment: serverB).adbServer)
    }

    func testHostOnlyChangeRemovesOldForwardBeforeReplacement() throws {
        persistSession(token: "token-A", localPort: 18080, environment: serverA)
        var changed = serverA
        changed["SIM_USE_BRIDGE_HOST"] = "192.0.2.30"

        try makeClient(environment: changed).pressKey(3)

        let calls = adbCalls()
        let removal = try XCTUnwrap(calls.firstIndex(of: "-s \(serial) forward --remove tcp:18080"))
        let creation = try XCTUnwrap(calls.firstIndex { $0.contains("forward tcp:0") })
        XCTAssertLessThan(removal, creation)
        assertNothingSent(toPort: 18080, withToken: "token-A")
        assertAllRequests(host: "192.0.2.30", port: 18081, authorizedWith: "token-B")
    }

    func testLegacyUnnormalisedIdentityWithoutServerIsRejectedWithoutRemoval() throws {
        let session = BridgeSession(token: "token-A", localPort: 18080, remotePort: 8080,
                                    connection: "adb=default host=127.0.0.1")
        BridgeSessionStore.write(session, udid: serial, home: home)
        XCTAssertNil(BridgeSessionStore.read(udid: serial, home: home)?.adbServer)

        try makeClient(environment: [:]).pressKey(3)

        assertNothingSent(toPort: 18080, withToken: "token-A")
        XCTAssertFalse(adbCalls().contains { $0.contains("forward --remove") })
    }

    func testDefaultPortChangeReusesSession() throws {
        persistSession(token: "token-A", localPort: 18080, environment: [:])
        try "\(serial) tcp:18080 tcp:8080\n".write(to: forwardList, atomically: true, encoding: .utf8)

        try makeClient(environment: ["ANDROID_ADB_SERVER_PORT": "5037"]).pressKey(3)

        assertAllRequests(host: "127.0.0.1", port: 18080, authorizedWith: "token-A")
        XCTAssertFalse(adbCalls().contains { $0.contains("forward --remove") || $0.contains("forward tcp:0") })
    }

    func testEquivalentDefaultDaemonIdentities() {
        XCTAssertEqual(
            BridgeConnection.daemonConnectionIdentity(udid: serial, environment: [:]),
            BridgeConnection.daemonConnectionIdentity(udid: serial, environment: ["ANDROID_ADB_SERVER_PORT": "5037"])
        )
    }

    func testAdbServerNormalisation() {
        for spec in ["default", "tcp:5037", "tcp:localhost:5037", "tcp:127.0.0.1:5037", "tcp:[::1]:5037"] {
            XCTAssertEqual(BridgeConnection.normalizeAdbServer(spec), "tcp:localhost:5037", spec)
        }
        for address in ["localhost", "127.0.0.1", "::1", "[::1]"] {
            for port in [nil, "5037", ""] as [String?] {
                var environment = ["ANDROID_ADB_SERVER_ADDRESS": address]
                environment["ANDROID_ADB_SERVER_PORT"] = port
                XCTAssertEqual(BridgeConnection(environment: environment).adbServer, "tcp:localhost:5037")
            }
        }
        for (spec, expected) in [
            ("tcp:5038", "tcp:localhost:5038"),
            ("tcp:192.0.2.10:5037", "tcp:192.0.2.10:5037"),
            ("tcp:ADB.EXAMPLE:5037", "tcp:adb.example:5037"),
            ("tcp:[fd00::1]:5037", "tcp:[fd00::1]:5037"),
            ("tcp:bad-port", "tcp:bad-port"),
            ("tcp:localhost:nope", "tcp:localhost:nope"),
            ("tcp:localhost:70000", "tcp:localhost:70000"),
            ("localfilesystem:/tmp/adb.sock", "localfilesystem:/tmp/adb.sock"),
        ] {
            XCTAssertEqual(BridgeConnection.normalizeAdbServer(spec), expected)
        }
        XCTAssertEqual(BridgeConnection(environment: ["ANDROID_ADB_SERVER_ADDRESS": "192.0.2.10"]).adbServer,
                       "tcp:192.0.2.10:5037")
    }

    // MARK: - Connection identity

    func testIdentityTracksEveryVariableThatMovesTheConnection() {
        let base = BridgeConnection(environment: [:]).identity
        XCTAssertEqual(BridgeConnection(environment: ["ADB_SERVER_SOCKET": ""]).identity, base, "empty equals unset")
        for env in [
            serverA,
            ["ANDROID_ADB_SERVER_ADDRESS": "192.0.2.10"],
            ["ANDROID_ADB_SERVER_PORT": "5038"],
            ["SIM_USE_BRIDGE_HOST": "192.0.2.30"],
        ] {
            XCTAssertNotEqual(BridgeConnection(environment: env).identity, base, "\(env) must change the identity")
        }
        XCTAssertNotEqual(BridgeConnection(environment: serverA).identity, BridgeConnection(environment: serverB).identity)
    }

    func testDaemonIdentityIsScopedToAndroidTargets() {
        XCTAssertNotNil(BridgeConnection.daemonConnectionIdentity(udid: serial, environment: serverA))
        XCTAssertNotEqual(
            BridgeConnection.daemonConnectionIdentity(udid: serial, environment: serverA),
            BridgeConnection.daemonConnectionIdentity(udid: serial, environment: serverB)
        )
        XCTAssertNil(
            BridgeConnection.daemonConnectionIdentity(udid: "1A2B3C4D-1A2B-1A2B-1A2B-1A2B3C4D5E6F", environment: serverA),
            "iOS simulator daemons do not depend on the adb connection"
        )
        XCTAssertNil(
            BridgeConnection.daemonConnectionIdentity(udid: "00008130-00066D2A10EB8D3A", environment: serverA),
            "physical iOS devices do not depend on the adb connection"
        )
    }

    /// Any serial adb can hand out reaches the per-device daemon, not just
    /// the shapes `PlatformRouter.looksLikeAndroid` recognises — wireless
    /// debugging (mDNS) serials run past its 32-character cap. Those
    /// daemons talk to adb all the same, so they must be scoped too.
    func testDaemonIdentityCoversSerialsOutsideTheAndroidHeuristic() {
        for udid in [
            "adb-R58M123ABC-AbCdEf._adb-tls-connect._tcp",
            "adb-R58M123ABC-AbCdEf._adb-tls-connect._tcp.",
            "192.0.2.5:5555",
        ] {
            let a = BridgeConnection.daemonConnectionIdentity(udid: udid, environment: serverA)
            let b = BridgeConnection.daemonConnectionIdentity(udid: udid, environment: serverB)
            XCTAssertNotNil(a, "\(udid) must carry a connection identity")
            XCTAssertNotEqual(a, b, "\(udid) must follow the adb server")
        }
    }

    /// `adb forward --list` failing says nothing about whether the cached
    /// forward is gone. Treating it as gone would open another forward on
    /// every such failure and strand the old one on the adb server, so
    /// the failure surfaces instead and the session is kept for the next
    /// call to confirm.
    func testForwardListFailureDoesNotOpenAnotherForward() throws {
        persistSession(token: "token-A", localPort: 18080, environment: serverA)
        failForwardList = true

        XCTAssertThrowsError(try makeClient(environment: serverA).pressKey(3))

        XCTAssertFalse(adbCalls().contains { $0.contains("forward tcp:0") }, "no new forward expected: \(adbCalls())")
        XCTAssertTrue(RecordingBridgeProtocol.requests().isEmpty, "unconfirmed forward must not be used")
        let stored = try XCTUnwrap(BridgeSessionStore.read(udid: serial, home: home))
        XCTAssertEqual(stored.localPort, 18080)
        XCTAssertEqual(stored.token, "token-A")
    }

    /// A forward that is confirmed gone is not ours to reuse, and there
    /// is nothing left on the server to clean up: the replacement is the
    /// only forward opened.
    func testConfirmedMissingForwardOpensExactlyOneReplacement() throws {
        persistSession(token: "token-A", localPort: 18080, environment: serverA)

        try makeClient(environment: serverA).pressKey(3)

        XCTAssertEqual(adbCalls().filter { $0.contains("forward tcp:0") }.count, 1, "\(adbCalls())")
        assertAllRequests(host: "192.0.2.10", port: 18081, authorizedWith: "token-B")
    }

    /// With more than one device on the adb server, `adb forward --remove`
    /// without `-s` fails ("more than one device/emulator"), so dropping a
    /// forward has to name the serial or the forward is left behind.
    func testInvalidateRemovesTheForwardForThisSerial() throws {
        let client = try makeClient(environment: serverA)
        try client.pressKey(3)

        client.invalidate()

        XCTAssertTrue(
            adbCalls().contains("-s \(serial) forward --remove tcp:18081"),
            "forward must be removed for this serial: \(adbCalls())"
        )
    }

    /// Nothing answers on the bridge port, even after reconnecting:
    /// both attempts must remove their forward for this serial, since
    /// no persisted session will be available to clean it up later.
    func testFailedReconnectRemovesEveryCreatedForward() throws {
        RecordingBridgeProtocol.reset(listenerAvailable: false)
        let client = try makeClient(environment: serverA)

        XCTAssertThrowsError(try client.ping())

        let calls = adbCalls()
        let creations = calls.filter { $0 == "-s \(serial) forward tcp:0 tcp:8080" }
        let removals = calls.filter { $0 == "-s \(serial) forward --remove tcp:18081" }
        XCTAssertEqual(creations.count, 2, "initial attempt and reconnect must each open a forward: \(calls)")
        XCTAssertEqual(removals.count, creations.count, "every created forward must be removed for this serial: \(calls)")
        XCTAssertNil(BridgeSessionStore.read(udid: serial, home: home))
    }

    // MARK: - Fixtures

    private func persistSession(token: String, localPort: Int, environment: [String: String]) {
        let session = BridgeSession(
            token: token,
            localPort: localPort,
            remotePort: BridgeClient.defaultRemotePort,
            connection: BridgeConnection(environment: environment).identity,
            adbServer: BridgeConnection(environment: environment).adbServer
        )
        BridgeSessionStore.write(session, udid: serial, home: home)
    }

    private func makeClient(environment: [String: String]) throws -> BridgeClient {
        let script = root.appendingPathComponent("adb")
        let body = """
            #!/bin/sh
            echo "$*" >> '\(adbLog.path)'
            case "$*" in
              *"forward --remove"*)
                # Real adb with several devices refuses this without -s.
                [ "$1" = "-s" ] || { echo "adb: error: more than one device/emulator" >&2; exit 1; } ;;
              *"forward --list"*) \(failForwardList ? "echo 'error: cannot connect to daemon' >&2; exit 1" : "cat '\(forwardList.path)' 2>/dev/null") ;;
              *"forward tcp:0 tcp:8080"*) echo 18081 ;;
              *"content query"*) echo "Row: 0 result=token-B" ;;
            esac
            exit 0

            """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingBridgeProtocol.self]
        return BridgeClient(
            adb: Adb(binaryPath: script.path, defaultTimeout: 5),
            serial: serial,
            urlSession: URLSession(configuration: config),
            environment: environment,
            sessionHome: home
        )
    }

    private func adbCalls() -> [String] {
        ((try? String(contentsOf: adbLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func assertNothingSent(toPort port: Int, withToken token: String, file: StaticString = #filePath, line: UInt = #line) {
        let requests = RecordingBridgeProtocol.requests()
        XCTAssertFalse(requests.contains { $0.port == port }, "request reached cached port \(port): \(requests)", file: file, line: line)
        XCTAssertFalse(
            requests.contains { $0.authorization == "Bearer \(token)" },
            "cached token \(token) was sent: \(requests)", file: file, line: line
        )
    }

    private func assertAllRequests(
        host: String, port: Int, authorizedWith token: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let requests = RecordingBridgeProtocol.requests()
        XCTAssertFalse(requests.isEmpty, "no bridge request was made", file: file, line: line)
        for request in requests {
            XCTAssertEqual(request.host, host, "\(request)", file: file, line: line)
            XCTAssertEqual(request.port, port, "\(request)", file: file, line: line)
        }
        XCTAssertTrue(
            requests.contains { $0.authorization == "Bearer \(token)" },
            "expected an authorized request with \(token): \(requests)", file: file, line: line
        )
    }
}

/// Answers bridge requests successfully unless no listener is available,
/// and records where they went.
final class RecordingBridgeProtocol: URLProtocol {
    struct Recorded: CustomStringConvertible {
        let host: String?
        let port: Int?
        let path: String
        let authorization: String?
        var description: String { "\(host ?? "?"):\(port ?? -1)\(path) auth=\(authorization ?? "none")" }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [Recorded] = []
    nonisolated(unsafe) private static var listenerAvailable = true

    static func reset(listenerAvailable: Bool = true) {
        lock.lock()
        recorded = []
        Self.listenerAvailable = listenerAvailable
        lock.unlock()
    }

    static func requests() -> [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url
        Self.lock.lock()
        Self.recorded.append(Recorded(
            host: url?.host,
            port: url?.port,
            path: url?.path ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization")
        ))
        let listenerAvailable = Self.listenerAvailable
        Self.lock.unlock()

        guard listenerAvailable else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }

        let body = url?.path == "/ping"
            ? #"{"status":"success","result":"pong","protocol_version":\#(BridgeClient.expectedProtocolVersion),"bridge_version":"test"}"#
            : #"{"status":"success"}"#
        let response = HTTPURLResponse(url: url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
