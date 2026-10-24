// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend

/// `SIM_USE_PERF=1` stage timing of Android `ui` reads.
final class AndroidUIPerfTests: XCTestCase {
    func testOffUnlessSimUsePerfIsSet() {
        XCTAssertNil(AndroidUIPerf(environment: [:]))
        XCTAssertNil(AndroidUIPerf(environment: ["SIM_USE_PERF": "0"]))
        XCTAssertNotNil(AndroidUIPerf(environment: ["SIM_USE_PERF": "1"]))
    }

    func testLineListsStagesInOrderWithTheBridgeBreakdown() throws {
        let perf = try XCTUnwrap(AndroidUIPerf(environment: ["SIM_USE_PERF": "1"]))
        for stage in ["ping", "fetch", "decode"] { perf.stage(stage) }
        let line = perf.line(bytes: 1234, nodes: 56, includeRaw: false, bridge: "root=1;walk=20;total=30")
        XCTAssertTrue(line.hasPrefix("[PERF] android-ui ping="), line)
        XCTAssertNotNil(line.range(of: #"ping=[0-9.]+ fetch=[0-9.]+ decode=[0-9.]+ total=[0-9.]+ "#, options: .regularExpression), line)
        XCTAssertTrue(line.hasSuffix(" bytes=1234 nodes=56 raw=false bridge=root=1;walk=20;total=30"), line)
        XCTAssertTrue(perf.line(bytes: 0, nodes: 0, includeRaw: true, bridge: nil).hasSuffix("bridge=-"))
    }
}
