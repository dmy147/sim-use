// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge

import android.accessibilityservice.AccessibilityService
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo
import com.linecorp.simuse.devicebridge.config.AuthManager
import com.linecorp.simuse.devicebridge.server.ActionRouter
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/** `/a11y_tree_full?visible=true` keeps invisible nodes but skips their descendants. */
class ActionRouterTreeVisibleOnlyTest {

    private val token = "test-token-1234"
    private lateinit var service: AccessibilityService
    private lateinit var router: ActionRouter
    private lateinit var hiddenGrandchild: AccessibilityNodeInfo
    private lateinit var hidden: AccessibilityNodeInfo

    private fun node(id: String, visible: Boolean, vararg children: AccessibilityNodeInfo): AccessibilityNodeInfo {
        val n = mockk<AccessibilityNodeInfo>(relaxed = true)
        every { n.viewIdResourceName } returns id
        every { n.isVisibleToUser } returns visible
        every { n.childCount } returns children.size
        children.forEachIndexed { i, c -> every { n.getChild(i) } returns c }
        every { n.windowId } returns 1
        return n
    }

    @Before
    fun setUp() {
        val authManager = mockk<AuthManager>()
        every { authManager.getOrCreateToken() } returns token
        service = mockk(relaxed = true)
        every { service.getSystemService(any()) } returns mockk<WindowManager>(relaxed = true)
        every { service.windows } returns emptyList()
        // root(visible) -> [hidden(invisible) -> [hiddenChild(visible) -> [hiddenGrandchild]], shown(visible) -> [shownChild]]
        hiddenGrandchild = node("hiddenGrandchild", true)
        hidden = node("hidden", false, node("hiddenChild", true, hiddenGrandchild))
        val shown = node("shown", true, node("shownChild", true))
        every { service.rootInActiveWindow } returns node("root", true, hidden, shown)
        router = ActionRouter(serviceProvider = { service }, authManager = authManager)
    }

    private fun tree(params: Map<String, String>): JSONObject =
        JSONObject(router.route("GET", "/a11y_tree_full", params, mapOf("authorization" to "Bearer $token")).body)
            .getJSONObject("result")

    private fun ids(n: JSONObject): List<String> {
        val out = mutableListOf(n.getString("resourceId"))
        val children = n.getJSONArray("children")
        for (i in 0 until children.length()) out += ids(children.getJSONObject(i))
        return out
    }

    private fun child(n: JSONObject, id: String): JSONObject {
        val children = n.getJSONArray("children")
        return (0 until children.length()).map { children.getJSONObject(it) }.first { it.getString("resourceId") == id }
    }

    @Test
    fun visibleOnlyKeepsInvisibleNodeAndSkipsItsDescendants() {
        val root = tree(mapOf("visible" to "true"))
        assertEquals(listOf("root", "hidden", "shown", "shownChild"), ids(root))
        val hiddenJson = child(root, "hidden")
        assertEquals(false, hiddenJson.getBoolean("visibleToUser"))
        assertEquals(0, hiddenJson.getJSONArray("children").length())
        assertEquals(true, child(root, "shown").getBoolean("visibleToUser"))
        verify(exactly = 0) { hidden.getChild(any()) }
    }

    @Test
    fun withoutParameterReturnsFullTree() {
        assertEquals(
            listOf("root", "hidden", "hiddenChild", "hiddenGrandchild", "shown", "shownChild"),
            ids(tree(emptyMap())),
        )
        assertEquals(
            listOf("root", "hidden", "hiddenChild", "hiddenGrandchild", "shown", "shownChild"),
            ids(tree(mapOf("visible" to "false"))),
        )
    }
}
