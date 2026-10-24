// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend

/// `ui` reads ask the bridge to skip invisible subtrees.
final class AndroidVisibleTreeTests: XCTestCase {
    func testTreePathCarriesTheVisibleParameter() {
        XCTAssertEqual(BridgeClient.treePath(filter: false, visibleOnly: true), "/a11y_tree_full?visible=true")
        XCTAssertEqual(BridgeClient.treePath(filter: true, visibleOnly: true), "/a11y_tree_full?filter=true&visible=true")
    }

    func testTreePathWithoutTheParameterIsUnchanged() {
        XCTAssertEqual(BridgeClient.treePath(filter: false, visibleOnly: false), "/a11y_tree_full")
        XCTAssertEqual(BridgeClient.treePath(filter: true, visibleOnly: false), "/a11y_tree_full?filter=true")
    }

    /// Opt-in: an IME-covered container can report itself invisible while
    /// its children stay visible. Raw reads always get the full tree.
    func testOnlyOptedInReadsWithoutRawAreVisibleOnly() {
        XCTAssertFalse(AndroidDeviceController.visibleOnlyTreeReads(includeRaw: false, environment: [:]))
        XCTAssertFalse(AndroidDeviceController.visibleOnlyTreeReads(includeRaw: false, environment: ["SIM_USE_VISIBLE_TREE": "0"]))
        XCTAssertTrue(AndroidDeviceController.visibleOnlyTreeReads(includeRaw: false, environment: ["SIM_USE_VISIBLE_TREE": "1"]))
        XCTAssertFalse(AndroidDeviceController.visibleOnlyTreeReads(includeRaw: true, environment: ["SIM_USE_VISIBLE_TREE": "1"]))
    }
}
