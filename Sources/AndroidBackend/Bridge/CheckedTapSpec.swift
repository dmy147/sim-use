// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Exact native identity captured by `android ui --json` (not an outline alias).
public struct CheckedTapSpec: Codable, Equatable, Sendable {
    public struct Ancestor: Codable, Equatable, Sendable {
        public let className: String
        public let resourceId: String
    }

    public struct Target: Codable, Equatable, Sendable {
        public let className: String
        public let resourceId: String
        public let uniqueId: String
        public let text: String
        public let contentDescription: String
        public let hint: String
        /// Complete root-first real-window ancestors, excluding the target and synthetic wrapper.
        public let ancestry: [Ancestor]
    }

    public struct Bounds: Codable, Equatable, Sendable {
        public let left: Int32
        public let top: Int32
        public let right: Int32
        public let bottom: Int32
    }

    public let target: Target
    public let expectedBounds: Bounds

    static func read(_ bytes: Data) throws -> CheckedTapSpec {
        let spec: CheckedTapSpec
        do {
            spec = try JSONDecoder().decode(CheckedTapSpec.self, from: bytes)
        } catch {
            throw CLIError(errorDescription: "Invalid checked-tap JSON on stdin: \(error)")
        }
        try spec.validate()
        return spec
    }

    func validate() throws {
        guard !target.className.isEmpty, target.ancestry.allSatisfy({ !$0.className.isEmpty }) else {
            throw CLIError(errorDescription: "Checked-tap target and ancestor className values must not be empty.")
        }
        guard expectedBounds.right > expectedBounds.left, expectedBounds.bottom > expectedBounds.top else {
            throw CLIError(errorDescription: "Checked-tap expectedBounds must have positive width and height.")
        }
    }

    func formBody() throws -> Data {
        let json = String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = json.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw CLIError(errorDescription: "Could not form-encode checked-tap JSON.")
        }
        return Data("spec=\(encoded)".utf8)
    }
}

public struct CheckedTapResult: Codable, Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let target: CheckedTapSpec.Target
    public let bounds: CheckedTapSpec.Bounds
}
