// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import com.linecorp.simuse.devicebridge.handler.GestureHandler
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkConstructor
import io.mockk.unmockkAll
import org.junit.After
import org.junit.Before
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Drag then hold still before lifting, so a scroll does not fling.
 * The hold continues the drag stroke only after the drag completed, and the call returns after both.
 */
class GestureHandlerDragHoldTest {

    // android.jar stubs return null from continueStroke on the JVM; give it a real-looking stroke.
    @Before
    fun stubContinuation() {
        mockkConstructor(GestureDescription.StrokeDescription::class)
        every { anyConstructed<GestureDescription.StrokeDescription>().continueStroke(any(), any(), any(), any()) } returns
            mockk(relaxed = true)
    }

    @After
    fun tearDown() = unmockkAll()

    private fun service(outcome: (Int, AccessibilityService.GestureResultCallback) -> Boolean): Pair<AccessibilityService, MutableList<Int>> {
        val service = mockk<AccessibilityService>()
        val dispatched = mutableListOf<Int>()
        every { service.dispatchGesture(any(), any(), any()) } answers {
            dispatched.add(dispatched.size)
            outcome(dispatched.size, secondArg())
        }
        return service to dispatched
    }

    @Test
    fun holdContinuesTheDragAfterItCompletes() {
        val (service, dispatched) = service { _, callback -> callback.onCompleted(null); true }
        assertTrue(GestureHandler().dragAndHold(service, 540f, 1817f, 540f, 639f, 75, 225))
        assertEquals(2, dispatched.size)
    }

    @Test
    fun cancelledDragDoesNotContinue() {
        val (service, dispatched) = service { _, callback -> callback.onCancelled(null); true }
        assertFalse(GestureHandler().dragAndHold(service, 540f, 1817f, 540f, 639f, 75, 225))
        assertEquals(1, dispatched.size)
    }

    @Test
    fun rejectedDragDoesNotContinue() {
        val (service, dispatched) = service { _, _ -> false }
        assertFalse(GestureHandler().dragAndHold(service, 540f, 1817f, 540f, 639f, 75, 225))
        assertEquals(1, dispatched.size)
    }

    @Test
    fun cancelledHoldFails() {
        val (service, dispatched) = service { n, callback -> if (n == 1) callback.onCompleted(null) else callback.onCancelled(null); true }
        assertFalse(GestureHandler().dragAndHold(service, 540f, 1817f, 540f, 639f, 75, 225))
        assertEquals(2, dispatched.size)
    }
}
