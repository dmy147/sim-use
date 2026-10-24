// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge

import android.accessibilityservice.AccessibilityService
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo
import com.linecorp.simuse.devicebridge.config.AuthManager
import com.linecorp.simuse.devicebridge.server.ActionRouter
import io.mockk.every
import io.mockk.mockk
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** `/a11y_tree_full` reports its stage timing in the additive `X-Simuse-Perf` header. */
class ActionRouterTreePerfHeaderTest {

    @Test
    fun treeResponseCarriesStageTiming() {
        val token = "test-token-1234"
        val authManager = mockk<AuthManager>()
        every { authManager.getOrCreateToken() } returns token
        val service = mockk<AccessibilityService>(relaxed = true)
        every { service.getSystemService(any()) } returns mockk<WindowManager>(relaxed = true)
        every { service.windows } returns emptyList()
        val root = mockk<AccessibilityNodeInfo>(relaxed = true)
        every { root.childCount } returns 0
        every { service.rootInActiveWindow } returns root
        val router = ActionRouter(serviceProvider = { service }, authManager = authManager)

        val resp = router.route("GET", "/a11y_tree_full", emptyMap(), mapOf("authorization" to "Bearer $token"))

        assertEquals(200, resp.statusCode)
        val perf = resp.headers.getValue(ActionRouter.PERF_HEADER)
        val keys = perf.split(";").map { it.substringBefore("=") }
        assertEquals(listOf("root", "walk", "secondary", "secondaryWindows", "toJson", "toString", "total"), keys)
        assertTrue(perf.split(";").all { it.substringAfter("=").toLongOrNull() != null })
    }

    @Test
    fun otherResponsesCarryNoExtraHeaders() {
        val router = ActionRouter(serviceProvider = { null }, authManager = mockk(relaxed = true))
        assertTrue(router.route("GET", "/ping", emptyMap(), emptyMap()).headers.isEmpty())
    }
}
