// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge

import android.accessibilityservice.AccessibilityService
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import com.linecorp.simuse.devicebridge.config.AuthManager
import com.linecorp.simuse.devicebridge.server.ActionRouter
import io.mockk.every
import io.mockk.mockk
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Before
import org.junit.Test

/** `/a11y_tree_full` reports the IME window state sampled with the tree. */
class ActionRouterTreeKeyboardTest {

    private val token = "test-token-1234"
    private lateinit var service: AccessibilityService
    private lateinit var router: ActionRouter

    @Before
    fun setUp() {
        val authManager = mockk<AuthManager>()
        every { authManager.getOrCreateToken() } returns token
        service = mockk(relaxed = true)
        every { service.getSystemService(any()) } returns mockk<WindowManager>(relaxed = true)
        val root = mockk<AccessibilityNodeInfo>(relaxed = true)
        every { root.childCount } returns 0
        every { root.windowId } returns 1
        every { service.rootInActiveWindow } returns root
        router = ActionRouter(serviceProvider = { service }, authManager = authManager)
    }

    private fun tree(): JSONObject =
        JSONObject(router.route("GET", "/a11y_tree_full", emptyMap(), mapOf("authorization" to "Bearer $token")).body)

    @Test
    fun reportsVisibleKeyboardWithImePackage() {
        val imeRoot = mockk<AccessibilityNodeInfo>(relaxed = true)
        every { imeRoot.packageName } returns "com.google.android.inputmethod.latin"
        val ime = mockk<AccessibilityWindowInfo>(relaxed = true)
        every { ime.type } returns AccessibilityWindowInfo.TYPE_INPUT_METHOD
        every { ime.root } returns imeRoot
        every { service.windows } returns listOf(ime)

        val keyboard = tree().getJSONObject("keyboard")
        assertEquals(true, keyboard.getBoolean("visible"))
        assertEquals("com.google.android.inputmethod.latin", keyboard.getString("ime_package"))
    }

    @Test
    fun reportsHiddenKeyboardWithoutImePackage() {
        every { service.windows } returns emptyList()

        val keyboard = tree().getJSONObject("keyboard")
        assertEquals(false, keyboard.getBoolean("visible"))
        assertFalse(keyboard.has("ime_package"))
    }
}
