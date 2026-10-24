// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge

import android.view.accessibility.AccessibilityEvent
import com.linecorp.simuse.devicebridge.service.EventLog
import io.mockk.every
import io.mockk.mockk
import org.junit.Assert.assertEquals
import org.junit.Test

class EventLogTest {
    @Test
    fun lineCarriesTimingAndSourceFieldsOnly() {
        val event = mockk<AccessibilityEvent>(relaxed = true)
        every { event.eventTime } returns 123456L
        every { event.eventType } returns AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED
        every { event.contentChangeTypes } returns AccessibilityEvent.CONTENT_CHANGE_TYPE_SUBTREE
        every { event.windowId } returns 7
        every { event.packageName } returns "com.example.app"
        every { event.className } returns "android.widget.FrameLayout"
        assertEquals(
            "t=123456 type=2048 ct=1 w=7 p=com.example.app c=android.widget.FrameLayout",
            EventLog.line(event),
        )
    }
}
