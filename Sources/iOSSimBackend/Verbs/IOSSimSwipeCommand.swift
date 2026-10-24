// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl
import SimUseCore

/// iOS Simulator backend for the `swipe` verb. Mirrors the flag
/// surface of top-level `Swipe` and is also reachable directly as
/// `sim-use ios swipe`. The top-level command resolves the target
/// platform via `PlatformRouter` and forwards iOS UDIDs through here.
public struct IOSSimSwipeCommand: SimUseExecutableCommand {
    /// Carries the resolved coordinates so `format(_:)` renders from
    /// the execution result instead of re-resolving the raw flags —
    /// same shape as `IOSSimTapCommand.ExecutionResult`.
    public struct ExecutionResult: Codable, CommandAdvisoryProviding {
        public let coordinates: SwipeCoordinates
        /// Excluded from the encoded `data` payload via `CodingKeys`
        /// — the envelope hoists it to the top-level `advisory` key.
        public var commandAdvisory: CommandAdvisory? = nil

        public init(coordinates: SwipeCoordinates, commandAdvisory: CommandAdvisory? = nil) {
            self.coordinates = coordinates
            self.commandAdvisory = commandAdvisory
        }

        private enum CodingKeys: String, CodingKey {
            case coordinates
        }
    }

    public static let configuration = CommandConfiguration(
        commandName: "swipe",
        abstract: "Perform a swipe gesture from one point to another on the screen."
    )

    @OptionGroup public var coordinates: SwipeCoordinateOptions

    @Option(name: .customLong("coordinate-space"), help: "Space the coordinates are given in: 'ui' (the default; visual space as printed by describe-ui, orientation-calibrated per command so outline coordinates stay correct on a rotated device) or 'native' (the device's native portrait points, no calibration).")
    public var coordinateSpace: CoordinateSpace = .ui

    @Option(name: .customLong("duration"), help: "Duration of the swipe in seconds.")
    public var duration: Double?

    @Option(name: .customLong("delta"), help: "Distance between touch points in pixels.")
    public var delta: Double?

    @Option(name: .customLong("pre-delay"), help: "Delay before starting the swipe in seconds.")
    public var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after completing the swipe in seconds.")
    public var postDelay: Double?

    @Option(name: .customLong("hold"), help: "End the drag slowly over this many seconds before lifting, so scroll views do not fling (0-5; a ~130 pt/s tail).")
    public var hold: Double?

    @OptionGroup public var device: DeviceOptions

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    /// Match the top-level `Swipe` and `AndroidSwipeCommand` so direct
    /// `sim-use ios swipe` calls aren't silent on success.
    public func format(_ result: ExecutionResult) -> CommandOutput {
        .line("✓ Swipe \(result.coordinates.displaySummary) completed successfully")
    }

    public func validate() throws {
        _ = try coordinates.resolve()
        try Self.validateTimingOptions(
            duration: duration,
            delta: delta,
            preDelay: preDelay,
            postDelay: postDelay,
            hold: hold
        )
    }

    /// Timing/granularity rules factored out as a static so the
    /// top-level cross-platform forwarder runs the same checks without
    /// re-implementing them. Coordinate rules live in
    /// `SwipeCoordinateOptions.resolve()`.
    public static func validateTimingOptions(
        duration: Double?,
        delta: Double?,
        preDelay: Double?,
        postDelay: Double?,
        hold: Double? = nil
    ) throws {
        if let hold {
            guard hold >= 0 && hold <= 5.0 else {
                throw ValidationError("--hold must be between 0 and 5 seconds.")
            }
        }

        if let duration {
            guard duration > 0 else {
                throw ValidationError("Duration must be greater than 0.")
            }
            // Same ceiling as pre/post-delay and the Android verbs.
            // Also catches millisecond values passed by habit from
            // `adb shell input swipe` — those belong in seconds here.
            guard duration <= 10.0 else {
                throw ValidationError("Duration must be at most 10 seconds. Durations are in seconds, not milliseconds — pass 0.3 for a 300 ms swipe.")
            }
        }

        if let delta {
            guard delta > 0 else {
                throw ValidationError("Delta must be greater than 0.")
            }
        }

        if let preDelay {
            guard preDelay >= 0 && preDelay <= 10.0 else {
                throw ValidationError("Pre-delay must be between 0 and 10 seconds.")
            }
        }

        if let postDelay {
            guard postDelay >= 0 && postDelay <= 10.0 else {
                throw ValidationError("Post-delay must be between 0 and 10 seconds.")
            }
        }
    }

    public func resolvedCoordinates() throws -> SwipeCoordinates {
        try coordinates.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        let logger = SimUseLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)
        // Resizable app session (issue #143): touch HID cannot reach the app.
        try await RoutingDisplayGuard.assertTouchInputReachesApp(udid: device.resolved, verb: "swipe", logger: logger)

        let coords = try coordinates.resolve()
        let swipeDuration = duration ?? 1.0
        let swipeDelta = delta ?? 50.0

        logger.info().log("Performing swipe from (\(coords.startX), \(coords.startY)) to (\(coords.endX), \(coords.endY))")
        logger.info().log("Duration: \(swipeDuration)s, Delta: \(swipeDelta)px")

        // ui (the default) maps the endpoints from the space describe-ui
        // prints; native dispatches them untouched.
        var advisory: CommandAdvisory? = nil
        let dispatch: (startX: Double, startY: Double, endX: Double, endY: Double)
        if coordinateSpace == .ui {
            let calibration = await UISpaceCalibrationLoader.load(
                udid: device.resolved,
                fallbackMessage: UISpaceCalibrationLoader.explicitCoordinatesFallback,
                logger: logger
            )
            advisory = calibration.advisory
            let start = calibration.hidPoint(x: coords.startX, y: coords.startY)
            let end = calibration.hidPoint(x: coords.endX, y: coords.endY)
            dispatch = (start.x, start.y, end.x, end.y)
            logger.info().log("Coordinates (HID space): (\(dispatch.startX), \(dispatch.startY)) to (\(dispatch.endX), \(dispatch.endY))")
        } else {
            dispatch = (coords.startX, coords.startY, coords.endX, coords.endY)
        }

        var events: [FBSimulatorHIDEvent] = []

        if let preDelay, preDelay > 0 {
            logger.info().log("Pre-delay: \(preDelay)s")
            events.append(FBSimulatorHIDEvent.delay(preDelay))
        }

        events.append(Self.swipeEvent(
            startX: dispatch.startX,
            startY: dispatch.startY,
            endX: dispatch.endX,
            endY: dispatch.endY,
            delta: swipeDelta,
            duration: swipeDuration,
            hold: hold ?? 0
        ))

        if let postDelay, postDelay > 0 {
            logger.info().log("Post-delay: \(postDelay)s")
            events.append(FBSimulatorHIDEvent.delay(postDelay))
        }

        let finalEvent = events.count == 1 ? events[0] : FBSimulatorHIDEvent.composite(events)

        try await HIDInteractor.performHIDEvent(
            finalEvent,
            for: device.resolved,
            logger: logger
        )

        logger.info().log("Swipe gesture completed successfully")
        return ExecutionResult(coordinates: coords, commandAdvisory: advisory)
    }

    /// The plain swipe is touch-down, samples along the line, then up.
    /// With `hold > 0` the drag ends short of the end and covers the rest
    /// slowly over `hold` seconds: one sample every ~30 ms,
    /// `holdStepPoints` each (~130 pt/s, below the ~150 pt/s at which
    /// lists were measured not to fling), then lifts. A
    /// stationary pause does not work on the simulator: the scroll view
    /// keeps the velocity of the last moving samples and still flings on
    /// lift, as do 1 pt creep samples (measured).
    nonisolated static func swipeEvent(
        startX: Double, startY: Double, endX: Double, endY: Double,
        delta: Double, duration: Double, hold: Double
    ) -> FBSimulatorHIDEvent {
        let distance = ((endX - startX) * (endX - startX) + (endY - startY) * (endY - startY)).squareRoot()
        let samples = holdSamples(hold: hold, distance: distance)
        guard samples > 0 else {
            return .swipe(startX, yStart: startY, xEnd: endX, yEnd: endY, delta: delta, duration: duration)
        }
        let ux = (endX - startX) / distance, uy = (endY - startY) / distance
        let creep = Double(samples) * holdStepPoints
        let dragEndX = endX - ux * creep, dragEndY = endY - uy * creep
        guard var events = FBSimulatorHIDEvent.swipe(
            startX, yStart: startY, xEnd: dragEndX, yEnd: dragEndY, delta: delta, duration: duration
        ).subEvents else { return .composite([]) }
        events.removeLast()  // the plain swipe's touch up at the drag end
        let gap = hold / Double(samples)
        for k in 1...samples {
            let remaining = creep - Double(k) * holdStepPoints
            events.append(.delay(gap))
            events.append(.touch(direction: .down, x: endX - ux * remaining, y: endY - uy * remaining))
        }
        events.append(.touch(direction: .up, x: endX, y: endY))
        return .composite(events)
    }

    nonisolated static let holdStepPoints = 4.0

    /// One slow sample per ~30 ms of hold (at least 2), capped so the
    /// slow tail covers at most half the drag; 0 (the plain swipe) without
    /// a hold or for a drag shorter than 2 samples' worth.
    nonisolated static func holdSamples(hold: Double, distance: Double) -> Int {
        guard hold > 0 else { return 0 }
        let n = min(max(2, Int((hold / 0.03).rounded())), Int(distance / (2 * holdStepPoints)))
        return n >= 2 ? n : 0
    }
}
