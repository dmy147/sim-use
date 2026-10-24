// SPDX-License-Identifier: Apache-2.0
import CoreFoundation
import Foundation
import SimUseCore

/// Fast decoding of the Android bridge tree into `JSONValue`.
///
/// `JSONValue.init(from:)` tries Bool, Int64, Double, String, array and
/// object in turn for every value, so a ~900 KB tree takes about a second
/// per decode. The bridge tree holds only integers, booleans, strings and
/// nulls, so it is parsed with `JSONSerialization` and converted directly.
/// Booleans are told apart from integers through `CFBoolean`. A payload
/// with a fractional number or an integer outside Int64 falls back to
/// `JSONValue.decode`, so rounding and overflow behave exactly as before.
/// The fast path relies on Darwin's `CFBoolean` bridging; other platforms
/// keep the generic decoder.
public enum AndroidRawJSON {
    static func decode(from data: Data) throws -> JSONValue {
        if let fast = try? convert(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) {
            return fast
        }
        return try JSONValue.decode(from: data)
    }

    /// Client-side decode of a daemon success envelope whose `data.raw`
    /// carries an Android tree: `raw` goes through the fast path, the rest
    /// of the envelope through `JSONDecoder`. Any envelope the fast path
    /// does not cover is decoded by `JSONDecoder` as a whole.
    public static func decodeDaemonSuccess<T: Decodable>(
        _ response: Data,
        settingRaw: (inout T, JSONValue) -> Void
    ) throws -> DaemonClientSuccessPayload<T> {
        if let fast = try? fastDaemonSuccess(response, settingRaw: settingRaw) {
            return fast
        }
        return try JSONDecoder().decode(DaemonClientSuccessPayload<T>.self, from: response)
    }

    private static func fastDaemonSuccess<T: Decodable>(
        _ response: Data,
        settingRaw: (inout T, JSONValue) -> Void
    ) throws -> DaemonClientSuccessPayload<T>? {
        guard var envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              var data = envelope["data"] as? [String: Any],
              let rawObject = data["raw"], !(rawObject is NSNull) else { return nil }
        let raw = try convert(rawObject)
        data["raw"] = NSNull()
        envelope["data"] = data
        let rest = try JSONDecoder().decode(
            DaemonClientSuccessPayload<T>.self,
            from: JSONSerialization.data(withJSONObject: envelope)
        )
        var result = rest.data
        settingRaw(&result, raw)
        return DaemonClientSuccessPayload(data: result, processAdvisory: rest.processAdvisory, advisory: rest.advisory)
    }

    private static func convert(_ value: Any) throws -> JSONValue {
        #if !canImport(Darwin)
        throw Unsupported.platform
        #else
        switch value {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let type = String(cString: number.objCType)
            guard type != "f", type != "d", let integer = Int64(number.stringValue) else {
                throw Unsupported.number
            }
            return .integer(integer)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(try array.map(convert))
        case let object as [String: Any]:
            return .object(try object.mapValues(convert))
        default:
            throw Unsupported.number
        }
        #endif
    }

    private enum Unsupported: Error { case number, platform }
}
