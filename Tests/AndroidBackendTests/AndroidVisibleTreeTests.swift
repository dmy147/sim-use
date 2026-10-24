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

    /// Pruning is opt-in. It dropped visible controls under an IME-covered container that
    /// reports itself invisible, and saved only ~12% of the walk.
    func testUIReadsAreFullUnlessVisibleOnlyIsRequested() {
        XCTAssertFalse(AndroidDeviceController.visibleOnlyTreeReads(environment: [:]))
        XCTAssertFalse(AndroidDeviceController.visibleOnlyTreeReads(environment: ["SIM_USE_VISIBLE_TREE": "0"]))
        XCTAssertTrue(AndroidDeviceController.visibleOnlyTreeReads(environment: ["SIM_USE_VISIBLE_TREE": "1"]))
    }
}
