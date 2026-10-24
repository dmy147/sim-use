// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Cross-platform `describe-ui` envelope. Both iOS and Android backends
/// produce this shape; the `platform` discriminator tells consumers
/// which schema `raw` follows. See plan §"Locked decisions — backend
/// parsing shape" (S1–S3) for rationale.
public struct DescribeUIResult: Codable, Equatable, Sendable {
    public enum Platform: String, Codable, Equatable, Sendable {
        // `case ios` matches `Device.Platform.ios` (rather than the
        // historically-styled `iOS = "ios"`). Swift-side callers use
        // `.ios` / `.android` uniformly; the wire raw value is `"ios"`
        // either way so the JSON envelope is unaffected.
        case ios
        case android
    }

    public let platform: Platform
    /// Platform-passthrough raw tree. iOS = AX tree shape; Android =
    /// bridge `ElementNode` tree shape. Different schemas, both
    /// documented under `schemas/`.
    ///
    /// `nil` when the caller did not request `--json`, or opted out
    /// with `--no-raw` — the raw tree is ~200 KB on a complex screen
    /// and serialising it across the daemon socket adds ~80 ms of
    /// encode/decode for stdout-only consumers. `outline` + `entries`
    /// carry everything the human / alias-cache paths need.
    public let raw: JSONValue?
    public let outline: String
    public let entries: [Outline.Entry]
    public let lists: [Outline.ListSummary]
    public let screen: Outline.Frame
    public let appLabel: String
    /// iOS = `CFBundleIdentifier`; Android = a11y tree root `package`.
    public let appPackage: String
    /// Android-only, app-agnostic crash-dialog signal (issue: timing-
    /// insensitive crash detection). Non-nil when the system "<app> keeps
    /// stopping" dialog is on screen; the same fact is rendered as a banner
    /// prepended to `outline`. Always `nil` on iOS and when no dialog is
    /// detected — Codable omits the key in that case, keeping it additive.
    public let crashDialog: CrashDialogSignal?
    /// Android soft-keyboard state sampled with the tree. `nil` on iOS
    /// and with an upstream bridge that does not report it — Codable omits the key then.
    public let keyboard: KeyboardSignal?

    public init(
        platform: Platform,
        raw: JSONValue?,
        outline: String,
        entries: [Outline.Entry],
        lists: [Outline.ListSummary],
        screen: Outline.Frame,
        appLabel: String,
        appPackage: String,
        crashDialog: CrashDialogSignal? = nil,
        keyboard: KeyboardSignal? = nil
    ) {
        self.platform = platform
        self.raw = raw
        self.outline = outline
        self.entries = entries
        self.lists = lists
        self.screen = screen
        self.appLabel = appLabel
        self.appPackage = appPackage
        self.crashDialog = crashDialog
        self.keyboard = keyboard
    }
}

/// Soft-keyboard visibility in the `keyboard-state --json` shape (`visible`, `imePackage`).
public struct KeyboardSignal: Codable, Equatable, Sendable {
    public let visible: Bool
    public let imePackage: String?

    public init(visible: Bool, imePackage: String?) {
        self.visible = visible
        self.imePackage = imePackage
    }
}