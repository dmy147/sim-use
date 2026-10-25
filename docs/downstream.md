# Downstream branch

The `downstream` branch is upstream [lycorp-jp/sim-use](https://github.com/lycorp-jp/sim-use) `main` at `c02295e` (v0.16.0 plus the Homebrew signature fix) with the changes below on top. Every change keeps upstream's behaviour unless a flag, an environment variable or a newer bridge asks for it, except where a section says otherwise.

## Versions

| Item | Value |
| --- | --- |
| CLI | `v0.16.0-local.12` (stamped at build time with `SIM_USE_VERSION`) |
| Bridge APK | versionCode **29**, versionName `0.16.0-local.11` |
| Bridge protocol | **4** (upstream: 2) |

The protocol differs from upstream on purpose: a protocol-2 bridge would ignore `/swipe` `hold` and has no `/tap_node`, so neither side silently interoperates with the other. The CLI from this branch refuses an upstream bridge and an upstream CLI refuses this bridge; install the bridge that matches the CLI.

## Changes

### Android

| Change | Interface |
| --- | --- |
| Faster raw `ui --json`: the bridge payload for `data.raw` is decoded with a Foundation fast path instead of generic `JSONValue` decoding, and the client forwards the daemon's validated success envelope without decoding and re-encoding it. `data.raw` content is unchanged. | none |
| Checked tap: `android tap-node` reads a target spec from stdin; the bridge checks identity, ancestry, visibility, enabled state, unchanged bounds and topmost coverage, then dispatches the ordinary tap. See [Checked tap](#checked-tap). | `sim-use android tap-node --device <serial> --json < spec.json`, bridge `POST /tap_node` (protocol 3+) |
| Keyboard visibility with the tree: `/a11y_tree_full` also returns the IME window state sampled right after the tree. | `data.keyboard {visible, imePackage}` in `android ui --json`, raw and `--no-raw`; absent with an upstream bridge |
| Swipe hold: drag, keep the pointer still, then lift, so the release velocity is ~0 and lists do not fling. The bridge answers after both parts completed. | `swipe --hold <seconds>` (0-5), bridge `/swipe` field `hold` (ms), protocol 4 |
| Accessibility event log for diagnosis: one logcat line per accessibility event (time, type, content change types, window, package, class; never node text). | `adb shell setprop log.tag.SimuseEvents DEBUG`; off by default |
| Stage timing of `ui` reads: one stderr line per read with host stages and the bridge's own breakdown. | `SIM_USE_PERF=1`; bridge response header `X-Simuse-Perf` (`root`, `walk`, `secondary`, `keyboard`, `toJson`, `toString`, `total` ms) |
| Invisible-subtree pruning: the bridge keeps each node whose `visibleToUser` is false but does not walk its descendants. Off by default: a container covered by the keyboard can report itself invisible while its children stay visible, and pruning then drops real controls. | `SIM_USE_VISIBLE_TREE=1`; bridge `GET /a11y_tree_full?visible=true` (older bridges ignore it) |

`SIM_USE_PERF` and `SIM_USE_VISIBLE_TREE` are read where the read runs: set them when the per-device daemon starts, or use `SIM_USE_NO_DAEMON=1`.

### iOS simulator

| Change | Interface |
| --- | --- |
| Daemon pipe leak fixed: every `launchctl list` read kept both pipes and their read ends alive (the process was never waited for, so its termination block held it), which in the long-lived daemon ended in failed spawns and empty `appPackage`. | none |
| Swipe hold: a stationary pause still flings on the simulator, so the drag stops short of the end point and covers the rest at ~130 pt/s (4 pt every ~30 ms) before lifting. | `swipe --hold <seconds>` (0-5), top level and `ios swipe` |
| Screenshots through the warm daemon instead of a fresh process (about 60 ms against 230 ms). `--output` is anchored at the caller's directory. The capture skips the liveness probe. Android and physical iOS stay in-process. | none |
| One HID stabilization sleep per typed text instead of one per key event (66 characters: 4.4 s to 0.3 s, no dropped characters). Taps and swipes keep their per-command sleep. | none |
| No per-command liveness probe in the iOS daemon (about 270 ms per command). `ui` resolves the foreground app through a cache keyed by the accessibility root pid and lists processes only when that pid changes; that read feeds the crash tracker. A crash is therefore reported by the next `ui` whose root changed, not by an input verb. `app-state` reads the live list as before. | none |

## Checked tap

`spec.json`:

```json
{
  "target": {
    "className": "android.widget.Button",
    "resourceId": "app:id/send",
    "uniqueId": "",
    "text": "Send",
    "contentDescription": "",
    "hint": "",
    "ancestry": [{"className": "android.widget.FrameLayout", "resourceId": ""}]
  },
  "expectedBounds": {"left": 10, "top": 20, "right": 110, "bottom": 80}
}
```

Fill every field from one `android ui --json` raw capture: native `hintText` becomes `hint`, native null `uniqueId` / `hintText` become `""`, `boundsInScreen` becomes `expectedBounds`. `ancestry` is the complete root-first chain of class/resource-id pairs, excluding the target and the synthetic `__simuse:multi_window__` wrapper. All six identity strings are compared exactly.

Success is `{ok:true,data:{x,y,target,bounds}}` after dispatch. A refusal exits nonzero with `{ok:false,error:"Bridge error (checked_tap_refused): <condition>: expected=... observed=..."}`. The command bypasses the daemon so stdin stays with the caller, and never replays the tap after a transport failure: observe the screen before retrying.

The checks are an accessibility-geometry approximation, not Android's touch dispatch: overlays absent from accessibility, custom touch interception and changes after the snapshot are not detected. The capture limits are 10,000 nodes, depth 256 and 5 s (`snapshot_deadline`).

## Behaviour inherited from upstream 0.16.0

- **iOS coordinate space.** Explicit iOS coordinates (`tap -x/-y`, `tap --point`, `swipe --from/--to`, `touch`, `multi-touch`) default to `--coordinate-space ui`, the visual space `ui` prints, calibrated per command by accessibility probes. Before 0.16.0 the default was `native` (device-native portrait points). In portrait on the main display both spaces give the same numbers. A caller that wants the pre-0.16.0 dispatch, with no calibration probes, passes `--coordinate-space native`; on an iPhone 17 Pro simulator the probes added about 30 ms to each `tap` and `swipe`. Android accepts the flag and ignores it.
- **Retry after a transient boot error.** Multi-step commands (`ios batch`) are not replayed by the client (`daemonAllowsTransientRetry`).

## Build

```sh
scripts/build-bridge.sh                     # bridge APK into the SwiftPM resources
./scripts/build.sh dev                      # idb frameworks (first time)
SIM_USE_VERSION=v0.16.0-local.12 swift build -c release
make test
(cd bridge && ./gradlew :app:testDebugUnitTest)
```

The release binary is `.build/release/sim-use`; keep its SwiftPM resource bundles beside it when copying it elsewhere. After a rebuild with the same version string, stop running daemons (`sim-use daemon stop --device <id>` or `--all`): the version gate restarts only a daemon whose version differs.

## Installing and switching back

`sim-use android init --device <serial>` installs the bridge bundled with the CLI. The package id is shared with upstream, so one device holds one bridge. To go back to upstream, uninstall the bridge (`adb -s <serial> uninstall com.linecorp.simuse.devicebridge`) and run `android init` from the upstream CLI. Uninstalling first avoids versionCode-downgrade and signer-mismatch errors. `android init` rewrites the enabled accessibility service list, so save `settings get secure enabled_accessibility_services` beforehand if other services are enabled.
