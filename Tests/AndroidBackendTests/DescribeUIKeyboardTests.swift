// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend
import SimUseCore

/// The tree response's IME state reaches `data.keyboard`, raw or not.
final class DescribeUIKeyboardTests: XCTestCase {
    private func tree(keyboard: String?) -> Data {
        let field = keyboard.map { ", \"keyboard\": \($0)" } ?? ""
        return Data("""
        {"status": "success", "display": {"width": 1080, "height": 2400}\(field),
         "result": {"resourceId": "", "package": "com.example.app", "className": "android.widget.FrameLayout",
                    "text": "", "contentDescription": "",
                    "boundsInScreen": {"left": 0, "top": 0, "right": 1080, "bottom": 2400},
                    "clickable": false, "longClickable": false, "scrollable": false, "focusable": false,
                    "focused": false, "enabled": true, "checkable": false, "checked": false, "selected": false,
                    "password": false, "children": []}}
        """.utf8)
    }

    private func encoded(_ result: DescribeUIResult) throws -> [String: Any] {
        let data = try JSONEnvelopeWriter.encodeSuccess(result)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(envelope["data"] as? [String: Any])
    }

    func testVisibleKeyboardReachesRawAndNoRawResults() throws {
        let bytes = tree(keyboard: #"{"visible": true, "ime_package": "com.google.android.inputmethod.latin"}"#)
        for includeRaw in [true, false] {
            let result = try AndroidDeviceController.describeUIResult(treeBytes: bytes, options: .default, includeRaw: includeRaw)
            let keyboard = try XCTUnwrap(try encoded(result)["keyboard"] as? [String: Any])
            XCTAssertEqual(keyboard["visible"] as? Bool, true)
            XCTAssertEqual(keyboard["imePackage"] as? String, "com.google.android.inputmethod.latin")
        }
    }

    func testHiddenKeyboardOmitsImePackage() throws {
        let result = try AndroidDeviceController.describeUIResult(
            treeBytes: tree(keyboard: #"{"visible": false}"#), options: .default, includeRaw: false)
        let keyboard = try XCTUnwrap(try encoded(result)["keyboard"] as? [String: Any])
        XCTAssertEqual(keyboard["visible"] as? Bool, false)
        XCTAssertNil(keyboard["imePackage"])
    }

    func testUpstreamBridgeWithoutKeyboardOmitsTheKey() throws {
        let result = try AndroidDeviceController.describeUIResult(treeBytes: tree(keyboard: nil), options: .default, includeRaw: true)
        XCTAssertNil(try encoded(result)["keyboard"])
    }

    func testDaemonForwardingAcceptsKeyboard() throws {
        let bytes = tree(keyboard: #"{"visible": true}"#)
        let result = try AndroidDeviceController.describeUIResult(treeBytes: bytes, options: .default, includeRaw: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let daemon = try encoder.encode(DaemonSuccessResponse(data: result))
        XCTAssertTrue(AndroidRawJSON.canForwardDaemonResponse(daemon))
    }
}
