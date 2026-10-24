// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import ArgumentParser
import FBSimulatorControl
import Foundation
import Testing

// iOS `swipe --hold`.
@Suite("Swipe hold")
@MainActor
struct SwipeHoldTests {

    @Test("No hold keeps upstream's swipe events unchanged")
    func noHoldIsUpstream() {
        let upstream = FBSimulatorHIDEvent.swipe(10, yStart: 600, xEnd: 10, yEnd: 200, delta: 50, duration: 0.3)
        #expect(IOSSimSwipeCommand.swipeEvent(startX: 10, startY: 600, endX: 10, endY: 200, delta: 50, duration: 0.3, hold: 0) == upstream)
    }

    @Test("Hold ends the drag with a slow 4 pt / 30 ms tail, then lifts at the end point")
    func holdComposition() throws {
        // 300 pt up, hold 0.15 s -> 5 tail samples of 4 pt: the fast part ends at y = 220.
        let fast = try #require(FBSimulatorHIDEvent.swipe(10, yStart: 500, xEnd: 10, yEnd: 220, delta: 10, duration: 0.3).subEvents)
        let held = try #require(IOSSimSwipeCommand.swipeEvent(startX: 10, startY: 500, endX: 10, endY: 200, delta: 10, duration: 0.3, hold: 0.15).subEvents)
        #expect(Array(held.prefix(fast.count - 1)) == Array(fast.dropLast()))
        var tail: [FBSimulatorHIDEvent] = []
        for y in [216.0, 212, 208, 204, 200] { tail += [.delay(0.03), .touch(direction: .down, x: 10, y: y)] }
        tail.append(.touch(direction: .up, x: 10, y: 200))
        #expect(Array(held.dropFirst(fast.count - 1)) == tail)
    }

    @Test("Tail sample count follows the hold and is capped at half the drag")
    func holdSampleCount() {
        #expect(IOSSimSwipeCommand.holdSamples(hold: 0, distance: 300) == 0)
        #expect(IOSSimSwipeCommand.holdSamples(hold: 0.15, distance: 300) == 5)
        #expect(IOSSimSwipeCommand.holdSamples(hold: 0.3, distance: 300) == 10)
        #expect(IOSSimSwipeCommand.holdSamples(hold: 0.01, distance: 300) == 2)
        #expect(IOSSimSwipeCommand.holdSamples(hold: 0.3, distance: 40) == 5)
        #expect(IOSSimSwipeCommand.holdSamples(hold: 0.3, distance: 12) == 0)
    }

    @Test("Hold is parsed on both the top-level and the iOS verb and forwarded")
    func argvParsing() throws {
        let top = try Swipe.parse(["--from", "10,600", "--to", "10,200", "--duration", "0.3", "--hold", "0.15", "--device", "X"])
        #expect(top.hold == 0.15)
        #expect(top.makeIOSSubcommand().hold == 0.15)
        let ios = try IOSSimSwipeCommand.parse(["--from", "10,600", "--to", "10,200", "--hold", "0.3", "--device", "X"])
        #expect(ios.hold == 0.3)
        #expect(try Swipe.parse(["--from", "10,600", "--to", "10,200", "--device", "X"]).hold == nil)
    }

    @Test("Hold outside 0-5 s is rejected")
    func holdRange() {
        for bad in [-0.1, 5.1] {
            #expect(throws: ValidationError.self) {
                try IOSSimSwipeCommand.validateTimingOptions(duration: 0.3, delta: nil, preDelay: nil, postDelay: nil, hold: bad)
            }
        }
    }
}
