// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge.service

import android.util.Log
import android.view.accessibility.AccessibilityEvent

/**
 * One logcat line per accessibility event, so an event stream can be
 * compared offline with what the host observed by polling. Off by default;
 * enable with `adb shell setprop log.tag.SimuseEvents DEBUG`. Fields only, never node text.
 */
object EventLog {
    const val TAG = "SimuseEvents"

    fun enabled(): Boolean = Log.isLoggable(TAG, Log.DEBUG)

    fun line(event: AccessibilityEvent): String =
        "t=${event.eventTime} type=${event.eventType} ct=${event.contentChangeTypes} " +
            "w=${event.windowId} p=${event.packageName ?: ""} c=${event.className ?: ""}"

    fun record(event: AccessibilityEvent?) {
        if (event != null && enabled()) Log.d(TAG, line(event))
    }
}
