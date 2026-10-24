// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import SimUseCore
@testable import AndroidBackend

/// `AndroidRawJSON` must produce exactly what the generic `JSONValue`
/// decoder produces, on the daemon (bridge bytes) and on the client
/// (daemon envelope), so `android ui --json` output is unchanged.
final class AndroidRawJSONTests: XCTestCase {
    func testScalarAndUnknownFieldSemanticsMatchTheGenericDecoder() throws {
        let sources = [
            "null", "true", "false", "0", "-0.0", "1", "1.0", "3.14", "1e3", "1e18",
            "9223372036854775807", "-9223372036854775808", "9223372036854775808",
            "18446744073709551615", "1.00000000000000000000000001", "9007199254740993.1",
            "-9223372036854775808.1", "1e-999", "[true,]",
            #"{"unknown":{"array":[true,1,false,0,null,{},[],"中文🙂 / \\\"\n"]},"decimal":1.25}"#,
        ]
        for source in sources {
            let bytes = Data(source.utf8)
            XCTAssertEqual(try AndroidRawJSON.decode(from: bytes), try JSONValue.decode(from: bytes), source)
        }
        for source in ["1e999", "{", "[true false]", "null trailing"] {
            XCTAssertThrowsError(try AndroidRawJSON.decode(from: Data(source.utf8)), source)
        }
    }

    func testLargeTreeDecodesIdenticallyOnDaemonAndClient() throws {
        let bytes = try Self.syntheticTree(rows: 160)
        let generic = try JSONValue.decode(from: bytes)
        let fast = try AndroidRawJSON.decode(from: bytes)
        XCTAssertEqual(fast, generic)

        let advisory = CommandAdvisory(kind: .fullScreenTapTarget, message: "test")
        let process = ProcessAdvisory(events: [
            ProcessEvent(kind: .disappeared, bundleId: "com.example.app", pid: 10, confidence: .high),
        ], pending: [])
        for (processAdvisory, commandAdvisory) in [(nil, nil), (process, advisory)] as [(ProcessAdvisory?, CommandAdvisory?)] {
            let response = try Self.daemonResponse(try Self.result(raw: generic), process: processAdvisory, advisory: commandAdvisory)
            let expected = try JSONDecoder().decode(DaemonClientSuccessPayload<DescribeUIResult>.self, from: response)
            let decoded: DaemonClientSuccessPayload<DescribeUIResult> = try AndroidRawJSON.decodeDaemonSuccess(response) { $0.raw = $1 }
            XCTAssertEqual(decoded.data, expected.data)
            XCTAssertEqual(decoded.processAdvisory, expected.processAdvisory)
            XCTAssertEqual(decoded.advisory, expected.advisory)
            XCTAssertEqual(
                try JSONEnvelopeWriter.encodeSuccess(decoded.data, processAdvisory: decoded.processAdvisory, advisory: decoded.advisory),
                try JSONEnvelopeWriter.encodeSuccess(expected.data, processAdvisory: expected.processAdvisory, advisory: expected.advisory)
            )
        }
    }

    func testClientFallsBackToTheGenericDecoder() throws {
        let cases: [JSONValue?] = [nil, .object(["fraction": .double(1.5), "flag": .bool(true)]), .null]
        for raw in cases {
            let response = try Self.daemonResponse(try Self.result(raw: raw))
            let expected = try JSONDecoder().decode(DaemonClientSuccessPayload<DescribeUIResult>.self, from: response)
            let decoded: DaemonClientSuccessPayload<DescribeUIResult> = try AndroidRawJSON.decodeDaemonSuccess(response) { $0.raw = $1 }
            XCTAssertEqual(decoded.data, expected.data)
        }
        XCTAssertThrowsError(try AndroidRawJSON.decodeDaemonSuccess(Data("{".utf8)) { (result: inout DescribeUIResult, raw) in result.raw = raw })
    }

    /// Opt-in offline timings, no device: `SIM_USE_RAW_BENCHMARK=1 swift test --filter AndroidRawJSONTests`.
    func testOfflineBenchmark() throws {
        guard ProcessInfo.processInfo.environment["SIM_USE_RAW_BENCHMARK"] == "1" else {
            throw XCTSkip("Set SIM_USE_RAW_BENCHMARK=1 to time the raw decode stages")
        }
        let bytes = try Self.syntheticTree(rows: 200)
        let response = try Self.daemonResponse(try Self.result(raw: try JSONValue.decode(from: bytes)))
        func ms(_ body: () throws -> Void) rethrows -> Double {
            var samples: [Double] = []
            for _ in 0..<5 {
                let start = DispatchTime.now().uptimeNanoseconds
                try body()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            return samples.sorted()[2]
        }
        let daemonGeneric = try ms { _ = try JSONValue.decode(from: bytes) }
        let daemonFast = try ms { _ = try AndroidRawJSON.decode(from: bytes) }
        let clientGeneric = try ms { _ = try JSONDecoder().decode(DaemonClientSuccessPayload<DescribeUIResult>.self, from: response) }
        let clientFast = try ms { _ = try AndroidRawJSON.decodeDaemonSuccess(response) { (result: inout DescribeUIResult, raw) in result.raw = raw } }
        print(String(format: "[raw-benchmark] tree=%dB envelope=%dB daemon generic=%.1fms fast=%.1fms client generic=%.1fms fast=%.1fms (median of 5)",
                     bytes.count, response.count, daemonGeneric, daemonFast, clientGeneric, clientFast))
    }

    // MARK: - Synthetic fixtures

    /// A bridge `/a11y_tree_full` envelope shaped like a long list screen:
    /// `rows` list cells of nine nodes each, with every field type the bridge
    /// emits (nulls, nested objects, escapes, non-ASCII text).
    static func syntheticTree(rows: Int) throws -> Data {
        func node(_ className: String, _ bounds: [Int], text: String = "", id: String = "",
                  clickable: Bool = false, children: [[String: Any]] = [],
                  collectionInfo: Any = NSNull(), itemInfo: Any = NSNull()) -> [String: Any] {
            [
                "boundsInScreen": ["left": bounds[0], "top": bounds[1], "right": bounds[2], "bottom": bounds[3]],
                "checkable": false, "checked": false, "children": children, "className": className,
                "clickable": clickable, "collectionInfo": collectionInfo, "collectionItemInfo": itemInfo,
                "contentDescription": text.isEmpty ? "" : "\(text) description", "enabled": true,
                "focusable": clickable, "focused": false, "hintText": NSNull(), "longClickable": false,
                "package": "com.example.app", "password": false,
                "resourceId": id.isEmpty ? "" : "com.example.app:id/\(id)", "scrollable": false,
                "selected": false, "stateDescription": NSNull(), "text": text, "uniqueId": NSNull(),
                "visibleToUser": true,
            ]
        }
        let cells = (0..<rows).map { row -> [String: Any] in
            let top = 200 + row * 120
            let leaves = (0..<8).map { column in
                node("android.widget.TextView", [column * 135, top, column * 135 + 135, top + 120],
                     text: "Row \(row) · item \(column) — café 🙂 \"q\" / \\", id: "cell_text_\(column)")
            }
            return node("android.view.ViewGroup", [0, top, 1080, top + 120], id: "cell", clickable: true,
                        children: leaves,
                        itemInfo: ["rowIndex": row, "columnIndex": 0, "rowSpan": 1, "columnSpan": 1, "isHeading": false])
        }
        let list = node("androidx.recyclerview.widget.RecyclerView", [0, 200, 1080, 2400], id: "list",
                        children: cells,
                        collectionInfo: ["rowCount": rows, "columnCount": 1, "itemCount": rows, "isHierarchical": false])
        let root = node("android.widget.FrameLayout", [0, 0, 1080, 2400], children: [list])
        let envelope: [String: Any] = ["status": "success", "result": root, "display": ["width": 1080, "height": 2400]]
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    static func result(raw: JSONValue?) throws -> DescribeUIResult {
        DescribeUIResult(platform: .android, raw: raw, outline: "outline", entries: [], lists: [],
                         screen: .init(x: 0, y: 0, width: 1080, height: 2400),
                         appLabel: "Example", appPackage: "com.example.app")
    }

    /// Encoded like `executeAsDaemonResponse`.
    static func daemonResponse(_ result: DescribeUIResult, process: ProcessAdvisory? = nil, advisory: CommandAdvisory? = nil) throws -> Data {
        let encoder = JSONEncoder()
        encoder.userInfo[.simUseDaemonResponse] = true
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(DaemonSuccessResponse(id: nil, data: result, processAdvisory: process, advisory: advisory))
    }
}
