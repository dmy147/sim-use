// SPDX-License-Identifier: Apache-2.0
import CoreFoundation
import Foundation
import SimUseCore

/// Avoid recursive, exception-based Codable dispatch for the bridge's integer-only tree.
enum AndroidRawJSON {
    static func decode(from data: Data) throws -> JSONValue {
        do {
            return try convert(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        } catch {
            // Foundation and JSONDecoder round some fractional/large numbers differently.
            return try JSONValue.decode(from: data)
        }
    }

    private static func convert(_ value: Any) throws -> JSONValue {
        switch value {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let type = String(cString: number.objCType)
            guard type != "f", type != "d", let integer = Int64(number.stringValue) else {
                throw UnsupportedRepresentation.number
            }
            return .integer(integer)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(try array.map(convert))
        case let object as [String: Any]:
            return .object(try object.mapValues(convert))
        default:
            throw UnsupportedRepresentation.number
        }
    }

    private enum UnsupportedRepresentation: Error { case number }

    /// Only canonical, typed UI envelopes may bypass the existing client decode/re-encode.
    static func canForwardDaemonResponse(_ data: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(ForwardableEnvelope.self, from: data) else {
            return false
        }
        return envelope.canForward
    }
}

private struct ForwardableEnvelope: Decodable {
    let canForward: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ok = try container.decode(Bool.self, forKey: .ok)
        _ = try container.decode(UIMetadata.self, forKey: .data)
        let advisory = try container.decodeIfPresent(CommandAdvisory.self, forKey: .advisory)
        let process = try container.decodeIfPresent(ProcessAdvisory.self, forKey: .process)
        canForward = ok && !container.contains(.id)
            && (!container.contains(.advisory) || advisory != nil)
            && (!container.contains(.process) || process?.isEmpty == false)
    }

    private enum CodingKeys: String, CodingKey { case ok, data, id, advisory, process }
}

/// Same required metadata as DescribeUIResult; raw has already been decoded in the daemon.
private struct UIMetadata: Decodable {
    let platform: DescribeUIResult.Platform
    let raw: NonNullJSON
    let outline: String
    let entries: [Outline.Entry]
    let lists: [Outline.ListSummary]
    let screen: Outline.Frame
    let appLabel: String
    let appPackage: String
    let crashDialog: CrashDialogSignal?
    let keyboard: KeyboardSignal?
}

private struct NonNullJSON: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard !container.decodeNil() else {
            throw DecodingError.valueNotFound(JSONValue.self, .init(
                codingPath: decoder.codingPath,
                debugDescription: "Null raw uses the existing typed result path."
            ))
        }
    }
}
