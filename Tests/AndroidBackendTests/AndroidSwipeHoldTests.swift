// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AndroidBackend

/// `android swipe --hold` drags, holds still, then lifts.
final class AndroidSwipeHoldTests: XCTestCase {
    private let base = ["--from", "540,1817", "--to", "540,639", "--device", "emulator-5556"]

    func testHoldParsesAndReachesTheBridgeBody() throws {
        let command = try AndroidSwipeCommand.parse(base + ["--duration", "0.075", "--hold", "0.225"])
        XCTAssertEqual(command.hold, 0.225)
        XCTAssertEqual(
            BridgeClient.swipeBody(startX: 540, startY: 1817, endX: 540, endY: 639, durationMs: 75, holdMs: 225),
            "startX=540&startY=1817&endX=540&endY=639&duration=75&hold=225"
        )
    }

    func testNoHoldKeepsThePlainSwipeBody() throws {
        XCTAssertNil(try AndroidSwipeCommand.parse(base).hold)
        XCTAssertEqual(
            BridgeClient.swipeBody(startX: 1, startY: 2, endX: 3, endY: 4, durationMs: 300, holdMs: 0),
            "startX=1&startY=2&endX=3&endY=4&duration=300"
        )
    }

    func testHoldOutsideZeroToFiveSecondsIsRejected() {
        XCTAssertThrowsError(try AndroidSwipeCommand.parse(base + ["--hold", "6"]))
        XCTAssertThrowsError(try AndroidSwipeCommand.parse(base + ["--hold", "-1"]))
    }

    func testProtocolFourIsRequired() {
        XCTAssertEqual(BridgeClient.expectedProtocolVersion, 4)
    }
}
