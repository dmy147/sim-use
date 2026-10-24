// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import SimUseCore
@testable import AndroidBackend
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class AndroidRawJSONTests: XCTestCase {
    func testLargeRawIsJSONEqualToUpstreamAcrossDaemonAndCLI() throws {
        let bytes = try fixture()
        XCTAssertGreaterThan(bytes.count, 900_000)
        let upstream = try result(bytes, raw: JSONValue.decode(from: bytes))
        let optimized = try result(bytes, raw: AndroidRawJSON.decode(from: bytes))
        XCTAssertEqual(optimized.raw, upstream.raw)

        let oldDaemon = try encoder().encode(DaemonSuccessResponse(data: upstream))
        let oldClient = try JSONDecoder().decode(DaemonClientSuccessPayload<DescribeUIResult>.self, from: oldDaemon)
        let oldOutput = try JSONEnvelopeWriter.encodeSuccess(oldClient.data)
        let forwarded = try encoder().encode(DaemonSuccessResponse(data: optimized))
        XCTAssertTrue(AndroidRawJSON.canForwardDaemonResponse(forwarded))
        XCTAssertEqual(try JSONValue.decode(from: forwarded), try JSONValue.decode(from: oldOutput))
        XCTAssertEqual(forwarded, oldOutput, "Sorted output also stays byte-identical for this captured schema")
    }

    func testFoundationDecodePreservesUpstreamScalarAndUnknownFieldSemantics() throws {
        let sources = [
            "null", "true", "false", "0", "-0.0", "1", "1.0", "3.14", "1e3", "1e18",
            "9223372036854775807", "-9223372036854775808", "9223372036854775808",
            "18446744073709551615", "1.00000000000000000000000001", "9007199254740993.1",
            "-9223372036854775808.1", "1e-999", "[true,]",
            #"{"unknown":{"array":[true,1,false,0,null,{},[],"中文🙂 / \\\"\n"]},"decimal":1.25}"#,
        ]
        for source in sources {
            let bytes = Data(source.utf8)
            XCTAssertEqual(
                try AndroidRawJSON.decode(from: bytes),
                try JSONValue.decode(from: bytes),
                source
            )
        }
        for source in ["1e999", "{", "[true false]", "null trailing"] {
            XCTAssertThrowsError(try AndroidRawJSON.decode(from: Data(source.utf8)), source)
        }
    }

    func testForwardingRequiresCanonicalTypedUISuccess() throws {
        let response = try encoder().encode(DaemonSuccessResponse(data: smallResult()))
        var command = try AndroidDescribeUICommand.parse(["--json", "--device", "offline-fixture"])
        XCTAssertTrue(command.canForwardDaemonJSON(response))
        command.noRaw = true
        XCTAssertFalse(command.canForwardDaemonJSON(response))
        XCTAssertFalse(AndroidKeyboardStateCommand().canForwardDaemonJSON(response))

        let invalid: [(inout [String: JSONValue]) -> Void] = [
            { $0.removeValue(forKey: "data") },
            { $0["ok"] = .bool(false) },
            { $0["id"] = .string("trace-id") },
            { $0["id"] = .null },
            { $0["data"] = .string("not a result") },
            { $0["advisory"] = .object(["kind": .string("future-kind"), "message": .string("test")]) },
            { $0["advisory"] = .null },
            { $0["process"] = .object(["events": .array([]), "pending": .array([])]) },
        ]
        for mutate in invalid {
            XCTAssertFalse(AndroidRawJSON.canForwardDaemonResponse(try modifying(response, mutate)))
        }
        for (key, replacement) in [("outline", JSONValue.bool(true)), ("entries", .string("wrong")), ("raw", .null)] {
            let changed = try modifying(response) { envelope in
                guard case .object(var data) = envelope["data"] else { return }
                data[key] = replacement
                envelope["data"] = .object(data)
            }
            XCTAssertFalse(AndroidRawJSON.canForwardDaemonResponse(changed))
        }
        let missingRaw = try modifying(response) { envelope in
            guard case .object(var data) = envelope["data"] else { return }
            data.removeValue(forKey: "raw")
            envelope["data"] = .object(data)
        }
        XCTAssertFalse(AndroidRawJSON.canForwardDaemonResponse(missingRaw))
        XCTAssertFalse(AndroidRawJSON.canForwardDaemonResponse(Data("{".utf8)))
    }

    func testForwardingPreservesAdvisoriesAndStandaloneEnvelope() throws {
        let result = smallResult()
        let advisory = CommandAdvisory(kind: .fullScreenTapTarget, message: "test")
        let process = ProcessAdvisory(events: [
            ProcessEvent(kind: .disappeared, bundleId: "com.example.fixture", pid: 10, confidence: .high),
        ], pending: [])
        let daemon = try encoder().encode(DaemonSuccessResponse(
            data: result, processAdvisory: process, advisory: advisory
        ))
        XCTAssertTrue(AndroidRawJSON.canForwardDaemonResponse(daemon))
        XCTAssertEqual(daemon, try JSONEnvelopeWriter.encodeSuccess(result, processAdvisory: process, advisory: advisory))
        XCTAssertNotEqual(daemon.last, 0x0A, "The CLI adds exactly one LF to the daemon's unframed bytes")
    }

    /// Opt-in, offline timings; no adb, bridge install, or device access.
    func testOfflineRawPipelineBenchmark() throws {
        guard ProcessInfo.processInfo.environment["SIM_USE_RAW_BENCHMARK"] == "1" else {
            throw XCTSkip("Set SIM_USE_RAW_BENCHMARK=1 to profile the offline host pipeline")
        }
        let bytes: Data
        if let path = ProcessInfo.processInfo.environment["SIM_USE_RAW_BENCHMARK_INPUT"] {
            bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            bytes = try fixture()
        }
        let sink = try XCTUnwrap(FileHandle(forWritingAtPath: "/dev/null"))
        defer { try? sink.close() }
        for iteration in 0..<6 {
            for optimized in [false, true] {
                var stages: [String: Double] = [:]
                let start = DispatchTime.now().uptimeNanoseconds
                let tree = try time("typedTreeDecode", stages: &stages) {
                    try JSONDecoder().decode(BridgeEnvelope<ElementNode>.self, from: bytes)
                }
                let root = try XCTUnwrap(tree.result)
                let outline = time("render", stages: &stages) {
                    AndroidOutlineRenderer.render(root: root, display: tree.display)
                }
                let raw = try time("rawDecode", stages: &stages) {
                    try optimized ? AndroidRawJSON.decode(from: bytes) : JSONValue.decode(from: bytes)
                }
                let result = makeResult(root: root, outline: outline, raw: raw)
                let daemon = try time("daemonSortedEncode", stages: &stages) {
                    try encoder().encode(DaemonSuccessResponse(data: result))
                }
                let response = try time("socketHop", stages: &stages) { try transport(daemon) }
                _ = try time("classify", stages: &stages) {
                    try JSONDecoder().decode(Peek.self, from: response)
                }
                let output: Data
                if optimized {
                    let canForward = time("clientForwardValidation", stages: &stages) {
                        AndroidRawJSON.canForwardDaemonResponse(response)
                    }
                    XCTAssertTrue(canForward)
                    output = response
                } else {
                    let decoded = try time("clientTypedDecode", stages: &stages) {
                        try JSONDecoder().decode(DaemonClientSuccessPayload<DescribeUIResult>.self, from: response)
                    }
                    output = try time("clientSortedEncode", stages: &stages) {
                        try JSONEnvelopeWriter.encodeSuccess(decoded.data)
                    }
                }
                time("stdoutDevNull", stages: &stages) { sink.write(output); sink.write(Data([0x0A])) }
                stages["totalHost"] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                let row = BenchmarkRow(mode: optimized ? "optimized" : "baseline", iteration: iteration,
                                       inputBytes: bytes.count, outputBytes: output.count, stagesMilliseconds: stages)
                print(String(decoding: try encoder().encode(row), as: UTF8.self))
            }
        }
    }

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "large-android-tree", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func result(_ bytes: Data, raw: JSONValue) throws -> DescribeUIResult {
        let tree = try JSONDecoder().decode(BridgeEnvelope<ElementNode>.self, from: bytes)
        let root = try XCTUnwrap(tree.result)
        return makeResult(root: root, outline: AndroidOutlineRenderer.render(root: root, display: tree.display), raw: raw)
    }

    private func makeResult(root: ElementNode, outline: Outline, raw: JSONValue) -> DescribeUIResult {
        DescribeUIResult(platform: .android, raw: raw, outline: outline.text, entries: outline.entries,
                         lists: outline.lists, screen: outline.screen, appLabel: outline.appLabel, appPackage: root.package)
    }

    private func smallResult() -> DescribeUIResult {
        DescribeUIResult(platform: .android, raw: .object(["unknown": .array([.bool(true), .integer(1), .null])]),
                         outline: "fixture", entries: [], lists: [], screen: .init(x: 0, y: 0, width: 1080, height: 2424),
                         appLabel: "fixture", appPackage: "com.example.fixture")
    }

    private func modifying(_ bytes: Data, _ mutate: (inout [String: JSONValue]) -> Void) throws -> Data {
        guard case .object(var object) = try JSONValue.decode(from: bytes) else {
            throw NSError(domain: "AndroidRawJSONTests", code: 1)
        }
        mutate(&object)
        return try encoder().encode(JSONValue.object(object))
    }

    private func time<T>(_ name: String, stages: inout [String: Double], _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try body()
        stages[name] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        return result
    }

    private func transport(_ data: Data) throws -> Data {
        var descriptors: [Int32] = [-1, -1]
        #if os(Linux)
        let socketType = Int32(SOCK_STREAM.rawValue)
        #else
        let socketType = SOCK_STREAM
        #endif
        guard socketpair(AF_UNIX, socketType, 0, &descriptors) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let readFD = descriptors[0]
        let writeFD = descriptors[1]
        defer { close(readFD) }
        var frame = data
        frame.append(0x0A)
        let framed = frame
        DispatchQueue.global().async {
            _ = DaemonSocket.writeAll(fd: writeFD, data: framed)
            close(writeFD)
        }
        return try XCTUnwrap(DaemonSocket.readLine(fd: readFD))
    }

    private struct Peek: Decodable {
        let ok: Bool
        let error: String?
        let kind: DaemonErrorKind?
        let hint: String?
    }

    private struct BenchmarkRow: Encodable {
        let mode: String
        let iteration: Int
        let inputBytes: Int
        let outputBytes: Int
        let stagesMilliseconds: [String: Double]
    }
}
