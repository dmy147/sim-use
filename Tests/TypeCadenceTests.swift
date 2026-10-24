// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import FBSimulatorControl
import Foundation
import Testing

// `type` sleeps once per text.
@Suite("Type cadence")
@MainActor
struct TypeCadenceTests {
    @Test("Every key event is sent without its own stabilization sleep, then one sleep follows")
    func oneSleepPerText() async throws {
        let events = try TextToHIDEvents.convertTextToHIDEvents("0xA1")
        var log: [String] = []
        try await IOSSimTypeCommand.send(events, perform: { event, stabilize in
            log.append(stabilize ? "event+sleep" : "event")
        }, stabilize: { log.append("sleep") })
        #expect(events.count == 10)  // 0, x, 1 = 2 events each; A = shift + key = 4
        #expect(log == Array(repeating: "event", count: events.count) + ["sleep"])
    }

    @Test("Empty text still ends with the single sleep only")
    func emptyText() async throws {
        var log: [String] = []
        try await IOSSimTypeCommand.send([], perform: { _, _ in log.append("event") }, stabilize: { log.append("sleep") })
        #expect(log == ["sleep"])
    }
}
