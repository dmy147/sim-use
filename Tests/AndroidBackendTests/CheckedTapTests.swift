// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SimUseCore
import XCTest
@testable import AndroidBackend

final class CheckedTapTests: XCTestCase {
    private let json = #"{"target":{"className":"android.widget.Button","resourceId":"app:id/send","uniqueId":"","text":"Send + &= % 日本語 🙂","contentDescription":"Send","hint":"","ancestry":[{"className":"android.widget.FrameLayout","resourceId":""}]},"expectedBounds":{"left":10,"top":20,"right":110,"bottom":80}}"#

    func testRegisteredAndroidCommandKeepsInputInClient() throws {
        let command = try AndroidCommand.parseAsRoot(["tap-node", "--device", "emulator-5556", "--json"])
        let tap = try XCTUnwrap(command as? AndroidTapNodeCommand)
        XCTAssertTrue(tap.jsonOutput)
        XCTAssertTrue(tap.daemonBypass)
    }

    func testSpecPreservesEveryIdentityFieldThroughFormEncoding() throws {
        let spec = try CheckedTapSpec.read(Data(json.utf8))
        let body = String(decoding: try spec.formBody(), as: UTF8.self)
        XCTAssertTrue(body.hasPrefix("spec="))
        XCTAssertFalse(body.dropFirst(5).contains("+"), "form + would become a space")
        let decoded = try XCTUnwrap(String(body.dropFirst(5)).removingPercentEncoding)
        XCTAssertEqual(try CheckedTapSpec.read(Data(decoded.utf8)), spec)
        XCTAssertEqual(spec.target.text, "Send + &= % 日本語 🙂")
    }

    func testSpecRejectsMissingIdentityAndAncestry() {
        for fragment in [
            #""uniqueId":"",""#,
            #""hint":"",""#,
            #","ancestry":[{"className":"android.widget.FrameLayout","resourceId":""}]"#,
        ] {
            let invalid = json.replacingOccurrences(of: fragment, with: "")
            XCTAssertThrowsError(try CheckedTapSpec.read(Data(invalid.utf8)))
        }
    }

    func testSpecRejectsEmptyClassAndInvalidBounds() {
        for invalid in [
            json.replacingOccurrences(of: "android.widget.Button", with: ""),
            json.replacingOccurrences(of: "android.widget.FrameLayout", with: ""),
            json.replacingOccurrences(of: #""right":110"#, with: #""right":10"#),
            json.replacingOccurrences(of: #""left":10"#, with: #""left":2147483648"#),
            json.replacingOccurrences(of: #""top":20"#, with: #""top":20.5"#),
        ] {
            XCTAssertThrowsError(try CheckedTapSpec.read(Data(invalid.utf8)))
        }
    }

    func testAnonymousIdentityAndSignedBoundsReachDeviceChecks() throws {
        let anonymous = json
            .replacingOccurrences(of: #""resourceId":"app:id/send""#, with: #""resourceId":"""#)
            .replacingOccurrences(of: #""text":"Send + &= % 日本語 🙂""#, with: #""text":"""#)
            .replacingOccurrences(of: #""contentDescription":"Send""#, with: #""contentDescription":"""#)
            .replacingOccurrences(of: #""left":10"#, with: #""left":-10"#)
        let spec = try CheckedTapSpec.read(Data(anonymous.utf8))
        XCTAssertEqual(spec.expectedBounds.left, -10)
        XCTAssertEqual(spec.target.text, "")
    }

    func testBridgeSendsStdinSpecAndDecodesObservedTarget() throws {
        let spec = try CheckedTapSpec.read(Data(json.utf8))
        let result = CheckedTapResult(x: 60, y: 50, target: spec.target, bounds: spec.expectedBounds)
        let payload = try JSONEncoder().encode(TestSuccess(result: result))
        try withClient(response: payload) { client in
            XCTAssertEqual(try client.tapNode(spec), result)
            let request = try XCTUnwrap(CheckedTapURLProtocol.actionRequests().first)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/tap_node")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
            let actualJSON = try XCTUnwrap(String(body.dropFirst(5)).removingPercentEncoding)
            XCTAssertEqual(try CheckedTapSpec.read(Data(actualJSON.utf8)), spec)
        }
    }

    func testRefusalConditionAndValuesSurviveHostErrorEnvelope() throws {
        let refusal = #"{"status":"error","code":"checked_tap_refused","condition":"unchanged_bounds","error":"unchanged_bounds: expected={\"left\":10}; observed={\"left\":11}","expected":{"left":10},"observed":{"left":11}}"#
        try withClient(response: Data(refusal.utf8), status: 409) { client in
            XCTAssertThrowsError(try client.tapNode(CheckedTapSpec.read(Data(json.utf8)))) { error in
                guard case BridgeError.applicationError(_, let code, let message) = error else {
                    return XCTFail("Expected structured bridge refusal, received \(error)")
                }
                XCTAssertEqual(code, "checked_tap_refused")
                XCTAssertTrue(message?.contains("unchanged_bounds") == true)
                let envelope = try? JSONDecoder().decode(TestError.self, from: JSONEnvelopeWriter.encodeError(error))
                XCTAssertEqual(envelope?.ok, false)
                XCTAssertTrue(envelope?.error.contains(#"expected={"left":10}"#) == true)
                XCTAssertTrue(envelope?.error.contains(#"observed={"left":11}"#) == true)
            }
            XCTAssertEqual(CheckedTapURLProtocol.actionRequests().count, 1)
        }
    }

    func testTransportFailureDoesNotReplayGesture() throws {
        try withClient(response: Data(), dropConnection: true) { client in
            XCTAssertThrowsError(try client.tapNode(CheckedTapSpec.read(Data(json.utf8)))) { error in
                XCTAssertTrue(error.localizedDescription.contains("outcome is unknown"))
                XCTAssertTrue(error.localizedDescription.contains("observe the screen before retrying"))
            }
            XCTAssertEqual(CheckedTapURLProtocol.actionRequests().count, 1, "dispatch may already have happened")
        }
    }

    func testPingReconnectBuildsActionForNewForwardAndSendsItOnce() throws {
        let spec = try CheckedTapSpec.read(Data(json.utf8))
        let result = CheckedTapResult(x: 60, y: 50, target: spec.target, bounds: spec.expectedBounds)
        try withClient(response: JSONEncoder().encode(TestSuccess(result: result)), failFirstPing: true) { client in
            XCTAssertEqual(try client.tapNode(spec), result)
            let actions = CheckedTapURLProtocol.actionRequests()
            XCTAssertEqual(actions.count, 1)
            XCTAssertEqual(actions.first?.url?.port, 18082)
        }
    }

    func testMalformedSuccessReportsUnknownOutcomeWithoutReplay() throws {
        for response in ["invalid JSON", #"{"status":"success"}"#, #"{"status":"success","result":{"x":60}}"#] {
            try withClient(response: Data(response.utf8)) { client in
                XCTAssertThrowsError(try client.tapNode(CheckedTapSpec.read(Data(json.utf8)))) { error in
                    XCTAssertTrue(error.localizedDescription.contains("outcome is unknown"))
                    XCTAssertTrue(error.localizedDescription.contains("observe the screen before retrying"))
                }
                XCTAssertEqual(CheckedTapURLProtocol.actionRequests().count, 1)
            }
        }
    }

    private struct TestSuccess: Encodable {
        let status = "success"
        let result: CheckedTapResult
    }

    private struct TestError: Decodable {
        let ok: Bool
        let error: String
    }

    private func withClient(
        response: Data,
        status: Int = 200,
        dropConnection: Bool = false,
        failFirstPing: Bool = false,
        _ action: (BridgeClient) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("checked-tap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("adb")
        let forwardCount = directory.appendingPathComponent("forward-count")
        try """
            #!/bin/sh
            case "$*" in
              *"forward tcp:0 tcp:8080"*)
                if [ -e '\(forwardCount.path)' ]; then echo 18082
                else touch '\(forwardCount.path)'; echo 18081
                fi ;;
              *"content query"*) echo 'Row: 0 result=test-token' ;;
              *"pm list packages"*) echo 'package:com.linecorp.simuse.devicebridge' ;;
            esac
            exit 0

            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        CheckedTapURLProtocol.reset(body: response, status: status, dropConnection: dropConnection, failFirstPing: failFirstPing)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CheckedTapURLProtocol.self]
        let client = BridgeClient(
            adb: Adb(binaryPath: script.path),
            serial: "emulator-5556",
            urlSession: URLSession(configuration: configuration),
            environment: [:],
            sessionHome: directory
        )
        try action(client)
    }
}

private final class CheckedTapURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var dropConnection = false
    nonisolated(unsafe) private static var failFirstPing = false
    nonisolated(unsafe) private static var pingAttempts = 0

    static func reset(body: Data, status: Int, dropConnection: Bool, failFirstPing: Bool) {
        lock.lock(); defer { lock.unlock() }
        requests = []
        Self.body = body
        Self.status = status
        Self.dropConnection = dropConnection
        Self.failFirstPing = failFirstPing
        Self.pingAttempts = 0
    }

    static func actionRequests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url?.path == "/tap_node" }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let ping = request.url?.path == "/ping"
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: 4096)
                guard count >= 0 else {
                    client?.urlProtocol(self, didFailWithError: stream.streamError ?? URLError(.cannotDecodeContentData))
                    return
                }
                if count == 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        Self.lock.lock()
        Self.requests.append(captured)
        let body = Self.body
        let status = Self.status
        let dropConnection = Self.dropConnection
        let failPing = ping && Self.failFirstPing && Self.pingAttempts == 0
        if ping { Self.pingAttempts += 1 }
        Self.lock.unlock()
        if failPing || (!ping && dropConnection) {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let payload = ping
            ? Data("{\"status\":\"success\",\"result\":\"pong\",\"protocol_version\":\(BridgeClient.expectedProtocolVersion),\"bridge_version\":\"test\"}".utf8)
            : body
        let response = HTTPURLResponse(url: request.url!, statusCode: ping ? 200 : status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
