// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge.handler

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.util.Log
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Dispatches touch gestures via `AccessibilityService.dispatchGesture()`.
 *
 * Fire-and-forget: we return immediately after `dispatchGesture` is
 * accepted by the framework, without waiting for the callback. Callers
 * verify state changes via the a11y tree after the gesture, which is
 * how csat operates and what the spike validated.
 *
 * Direct lift from csat's `GestureHandler` shape; same constants.
 */
class GestureHandler {

    fun tap(service: AccessibilityService, x: Float, y: Float): Boolean {
        val path = Path().apply {
            moveTo(x, y)
            lineTo(x, y)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0, TAP_DURATION)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        return dispatch(service, gesture, "tap($x,$y)")
    }

    fun swipe(
        service: AccessibilityService,
        startX: Float,
        startY: Float,
        endX: Float,
        endY: Float,
        duration: Long,
    ): Boolean {
        val clamped = clampSwipeDuration(duration)
        val path = Path().apply {
            moveTo(startX, startY)
            lineTo(endX, endY)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0, clamped)
        return dispatch(service, GestureDescription.Builder().addStroke(stroke).build(),
            "swipe($startX,$startY -> $endX,$endY)")
    }

    /**
     * Drag from start to end over [moveMs], then keep the pointer
     * still for [holdMs] before lifting, so the release velocity is ~0 and lists do not fling. Unlike
     * the other gestures this waits for each part: the hold must continue a completed drag, and the
     * caller observes only after the whole gesture.
     */
    fun dragAndHold(
        service: AccessibilityService,
        startX: Float,
        startY: Float,
        endX: Float,
        endY: Float,
        moveMs: Long,
        holdMs: Long,
    ): Boolean {
        val move = Path().apply {
            moveTo(startX, startY)
            lineTo(endX, endY)
        }
        val drag = GestureDescription.StrokeDescription(move, 0, clampSwipeDuration(moveMs), true)
        if (!dispatchAndWait(service, drag, moveMs, "drag($startX,$startY -> $endX,$endY)")) return false
        val still = Path().apply {
            moveTo(endX, endY)
            lineTo(endX, endY)
        }
        val hold = drag.continueStroke(still, 0, clampSwipeDuration(holdMs), false)
        return dispatchAndWait(service, hold, holdMs, "hold($endX,$endY)")
    }

    private fun dispatchAndWait(
        service: AccessibilityService,
        stroke: GestureDescription.StrokeDescription,
        durationMs: Long,
        label: String,
    ): Boolean {
        val builder = GestureDescription.Builder()
        builder.addStroke(stroke)
        val done = CountDownLatch(1)
        var completed = false
        val callback = object : AccessibilityService.GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                completed = true
                done.countDown()
            }

            override fun onCancelled(gestureDescription: GestureDescription?) {
                done.countDown()
            }
        }
        return try {
            if (!service.dispatchGesture(builder.build(), callback, null)) {
                Log.d(TAG, "$label rejected")
                return false
            }
            val finished = done.await(durationMs + GESTURE_WAIT_SLACK_MS, TimeUnit.MILLISECONDS)
            Log.d(TAG, "$label finished=$finished completed=$completed")
            finished && completed
        } catch (e: Exception) {
            Log.e(TAG, "$label failed", e)
            false
        }
    }

    fun gesture(service: AccessibilityService, strokes: List<StrokeParams>): Boolean {
        val builder = GestureDescription.Builder()
        for (s in strokes) {
            val path = Path()
            val waypoints = s.path
            if (waypoints != null && waypoints.size >= 2) {
                // Polyline shape — used by sim-use rotate presets, which
                // sample an arc Swift-side into a sequence of waypoints
                // and pass them through here. Dispatching the curved
                // path natively via Path.lineTo() avoids the parasitic
                // pinch that a single linear chord would introduce
                // (mid-trajectory finger distance shrinks below the
                // starting diameter for ≤90° rotations and drops to 0
                // at 180°).
                val first = waypoints.first()
                path.moveTo(first.x, first.y)
                for (i in 1 until waypoints.size) {
                    val p = waypoints[i]
                    path.lineTo(p.x, p.y)
                }
            } else {
                path.moveTo(s.startX, s.startY)
                path.lineTo(s.endX, s.endY)
            }
            builder.addStroke(GestureDescription.StrokeDescription(path, s.startTime, s.duration))
        }
        return dispatch(service, builder.build(), "gesture(${strokes.size})")
    }

    private fun dispatch(
        service: AccessibilityService,
        gesture: GestureDescription,
        label: String,
    ): Boolean =
        try {
            val ok = service.dispatchGesture(gesture, null, null)
            Log.d(TAG, "$label dispatched=$ok")
            ok
        } catch (e: Exception) {
            Log.e(TAG, "$label failed", e)
            false
        }

    data class StrokeParams(
        val startX: Float,
        val startY: Float,
        val endX: Float,
        val endY: Float,
        val startTime: Long,
        val duration: Long,
        val path: List<Point>? = null,
    )

    data class Point(val x: Float, val y: Float)

    companion object {
        private const val TAG = "SimuseGesture"
        private const val TAP_DURATION = 50L
        // The sim-use client validates `--duration` up to 10 s and
        // delivers long-press holds as /swipe with start == end, so the
        // ceiling must cover the full client range — a silently
        // shortened hold breaks e.g. 10 s long-press flows. The bound
        // exists only against runaway requests; GestureDescription
        // itself accepts far longer strokes.
        internal const val MIN_SWIPE_DURATION = 10L
        internal const val MAX_SWIPE_DURATION = 10_000L
        // Completion callbacks arrive on the main thread; allow for its scheduling on a busy device.
        private const val GESTURE_WAIT_SLACK_MS = 2_000L

        internal fun clampSwipeDuration(duration: Long): Long =
            duration.coerceIn(MIN_SWIPE_DURATION, MAX_SWIPE_DURATION)
    }
}