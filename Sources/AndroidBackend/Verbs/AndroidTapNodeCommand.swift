// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// Android actionability checks and gesture run together on the device.
public struct AndroidTapNodeCommand: SimUseExecutableCommand {
    public typealias ExecutionResult = CheckedTapResult

    public static let configuration = CommandConfiguration(
        commandName: "tap-node",
        abstract: "Read a native target spec from stdin, check it on device, and tap its centre."
    )

    @OptionGroup public var device: AndroidDeviceOptions
    @Flag(name: .customLong("json"), help: "Emit {ok,data:{x,y,target,bounds}} or {ok:false,error} with the failed check and observed values.")
    public var jsonOutput: Bool = false

    public init() {}

    // Keep the spec off child-process argv and out of the daemon's /dev/null stdin.
    public var daemonBypass: Bool { true }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
        try AndroidCommandDeviceValidation.requireAndroid(serial: device.resolved, verb: "tap-node")
    }

    public func execute() async throws -> ExecutionResult {
        let spec = try CheckedTapSpec.read(FileHandle.standardInput.readDataToEndOfFile())
        return try AndroidDeviceController().bridge(serial: device.resolved).tapNode(spec)
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        CommandOutput(stdout: "✓ Checked tap at (\(result.x), \(result.y)) dispatched\n")
    }
}
