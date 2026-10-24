// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge

import android.accessibilityservice.AccessibilityService
import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import com.linecorp.simuse.devicebridge.handler.CheckedTapHandler
import com.linecorp.simuse.devicebridge.handler.CheckedTapHandler.Ancestor
import com.linecorp.simuse.devicebridge.handler.CheckedTapHandler.Bounds
import com.linecorp.simuse.devicebridge.handler.CheckedTapHandler.Identity
import com.linecorp.simuse.devicebridge.handler.CheckedTapHandler.Node
import com.linecorp.simuse.devicebridge.handler.CheckedTapHandler.Spec
import com.linecorp.simuse.devicebridge.handler.CheckedTapHandler.Window
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CheckedTapHandlerTest {
    private val display = Bounds(0, 0, 100, 200)
    private val targetBounds = Bounds(20, 40, 60, 80)
    private val rootIdentity = Identity("Root", "app:id/root", "", "", "", "")
    private val targetIdentity = Identity("Button", "app:id/pay", "unique", "Pay", "Confirm payment", "")
    private val spec = Spec(targetIdentity, listOf(rootIdentity.ancestor()), targetBounds)
    private val handler = CheckedTapHandler()

    private fun target(
        identity: Identity = targetIdentity,
        bounds: Bounds = targetBounds,
        visible: Boolean = true,
        enabled: Boolean = true,
        order: Int = 1,
        children: List<Node> = emptyList(),
    ) = Node(identity, bounds, visible, enabled, order, children)

    private fun root(children: List<Node>, visible: Boolean = true, enabled: Boolean = true, bounds: Bounds = display) =
        Node(rootIdentity, bounds, visible, enabled, 0, children)

    private fun window(root: Node?, layer: Int = 1, id: Int = 1, bounds: Bounds = display) = Window(id, layer, bounds, root)

    private fun refusal(condition: String, windows: List<Window>, expected: Spec = spec) {
        val failure = runCatching { handler.check(expected, windows, display) }.exceptionOrNull()
        assertEquals(condition, failure?.message)
    }

    @Test
    fun exactUniqueTargetDispatchPointMatchesConsumerRounding() {
        val bounds = Bounds(20, 40, 61, 81)
        val checked = handler.check(spec.copy(expectedBounds = bounds), listOf(window(root(listOf(target(bounds = bounds))))), display)
        assertEquals(41, checked.x)
        assertEquals(61, checked.y)
    }

    @Test
    fun everyIdentityFieldAndCompleteRootFirstAncestryMustMatch() {
        for (identity in listOf(
            targetIdentity.copy(className = "TextView"), targetIdentity.copy(resourceId = "other"),
            targetIdentity.copy(uniqueId = "other"), targetIdentity.copy(text = "Paid"),
            targetIdentity.copy(contentDescription = "other"), targetIdentity.copy(hint = "other"),
        )) refusal("unique_match", listOf(window(root(listOf(target(identity = identity))))))
        refusal("unique_match", listOf(window(root(listOf(target())))), spec.copy(ancestry = emptyList()))
        refusal("unique_match", listOf(window(root(listOf(target())))), spec.copy(ancestry = listOf(Ancestor("other", ""))))
    }

    @Test
    fun duplicateIdentityIsRefusedEvenIfOnlyOneBoundsMatches() {
        refusal("unique_match", listOf(window(root(listOf(target(), target(bounds = Bounds(1, 1, 10, 10)))))))
    }

    @Test
    fun changedBoundsAreRefused() {
        refusal("unchanged_bounds", listOf(window(root(listOf(target(bounds = Bounds(21, 40, 61, 80)))))))
    }

    @Test
    fun selfAndAncestorVisibilityAndEnabledStateAreRequired() {
        refusal("visible_enabled_chain", listOf(window(root(listOf(target(visible = false))))))
        refusal("visible_enabled_chain", listOf(window(root(listOf(target(enabled = false))))))
        refusal("visible_enabled_chain", listOf(window(root(listOf(target()), visible = false))))
        refusal("visible_enabled_chain", listOf(window(root(listOf(target()), enabled = false))))
    }

    @Test
    fun displayWindowAndAncestorClippingAreRefused() {
        val outside = Bounds(-1, 40, 60, 80)
        refusal("display_bounds", listOf(window(root(listOf(target(bounds = outside)), bounds = Bounds(-10, 0, 100, 200)))),
            spec.copy(expectedBounds = outside))
        refusal("window_bounds", listOf(window(root(listOf(target())), bounds = Bounds(0, 0, 50, 200))))
        refusal("ancestor_bounds", listOf(window(root(listOf(target()), bounds = Bounds(0, 0, 50, 200)))))
    }

    @Test
    fun higherDrawingOrderSiblingCoversTargetEvenWhenDisabled() {
        val cover = target(identity = targetIdentity.copy(resourceId = "overlay"), order = 2, enabled = false)
        refusal("topmost_node", listOf(window(root(listOf(target(), cover)))))
        // Enumeration order is irrelevant; the target has the larger drawing order.
        handler.check(spec, listOf(window(root(listOf(cover.copy(drawingOrder = 0), target())))), display)
        // A hidden higher-order sibling does not cover the target.
        handler.check(spec, listOf(window(root(listOf(target(), cover.copy(visible = false))))), display)
    }

    @Test
    fun drawingOrderIsComparedWithinSiblingBranches() {
        val backgroundLeaf = target(identity = targetIdentity.copy(resourceId = "background"), order = 999)
        val background = Node(Identity("Panel", "background", "", "", "", ""), display, true, true, 0, listOf(backgroundLeaf))
        val foreground = Node(Identity("Panel", "foreground", "", "", "", ""), display, true, true, 2, listOf(target(order = 0)))
        val nestedSpec = spec.copy(ancestry = spec.ancestry + foreground.identity.ancestor())
        handler.check(nestedSpec, listOf(window(root(listOf(background, foreground)))), display)
    }

    @Test
    fun coveringDescendantOutsideHigherOrderContainerRefusesUnderlyingTarget() {
        val cover = target(identity = targetIdentity.copy(resourceId = "overlay-child"), order = 0)
        val container = Node(Identity("Panel", "overlay", "", "", "", ""), Bounds(70, 0, 100, 200),
            true, true, 2, listOf(cover))
        refusal("window_hit_available", listOf(window(root(listOf(target(), container)))))
        // A hidden ancestor removes the entire branch from visible coverage.
        handler.check(spec, listOf(window(root(listOf(target(), container.copy(visible = false))))), display)
    }

    @Test
    fun tiedOrUnknownCompetingDrawingOrderIsRefused() {
        val cover = target(identity = targetIdentity.copy(resourceId = "overlay"), order = 1)
        refusal("drawing_order_unambiguous", listOf(window(root(listOf(target(), cover)))))
        refusal("drawing_order_unambiguous", listOf(window(root(listOf(target(order = -1))))))
        refusal("drawing_order_unambiguous", listOf(window(root(listOf(target(), cover.copy(drawingOrder = -1))))))
    }

    @Test
    fun targetDescendantCanBeTheTopmostNode() {
        val label = target(identity = targetIdentity.copy(className = "TextView", resourceId = "label"), order = 0)
        handler.check(spec, listOf(window(root(listOf(target(children = listOf(label)))))), display)
    }

    @Test
    fun higherWindowLayerAndLayerTiesAreRefused() {
        val app = window(root(listOf(target())))
        val overlay = window(root(emptyList()).copy(identity = rootIdentity.copy(resourceId = "overlay")), layer = 2, id = 2)
        refusal("topmost_window", listOf(app, overlay))
        refusal("window_layer_unambiguous", listOf(app, overlay.copy(layer = 1)))
        // A higher-layer window with no root/descendant coverage at the point does not cover the target.
        val outside = Bounds(70, 0, 100, 200)
        handler.check(spec, listOf(app, overlay.copy(bounds = outside, root = overlay.root!!.copy(bounds = outside))), display)
        // Window bounds alone cannot hide a potentially covering root/descendant.
        refusal("topmost_window", listOf(app, overlay.copy(bounds = outside)))
    }

    @Test
    fun missingWindowRootIsRefused() {
        refusal("window_root_available", listOf(window(root(listOf(target()))), window(null, layer = 2, id = 2)))
        refusal("windows_available", emptyList())
    }

    @Test
    fun parserRequiresExactStringsCompleteAncestryAndIntegralInt32Bounds() {
        fun json() = JSONObject().put("target", spec.targetJson()).put("expectedBounds", targetBounds.toJson())
        assertEquals(spec, Spec.parse(json().toString()))
        for (field in listOf("className", "resourceId", "uniqueId", "text", "contentDescription", "hint", "ancestry")) {
            val input = json()
            input.getJSONObject("target").remove(field)
            assertTrue("missing $field", runCatching { Spec.parse(input.toString()) }.isFailure)
        }
        for (invalid in listOf("\"20\"", "20.5", "2147483648")) {
            val input = json()
            input.put("expectedBounds", JSONObject("{\"left\":$invalid,\"top\":40,\"right\":60,\"bottom\":80}"))
            assertTrue("bad coordinate $invalid", runCatching { Spec.parse(input.toString()) }.isFailure)
        }
        for (field in listOf("className", "resourceId", "uniqueId", "text", "contentDescription", "hint")) {
            val input = json()
            input.getJSONObject("target").put(field, 42)
            assertTrue("non-string $field", runCatching { Spec.parse(input.toString()) }.isFailure)
        }
        val invalidAncestor = json()
        invalidAncestor.getJSONObject("target").getJSONArray("ancestry").getJSONObject(0).put("className", "")
        assertTrue(runCatching { Spec.parse(invalidAncestor.toString()) }.isFailure)
    }

    @Test
    fun refreshedNodesAreRecycledAndOnlySuccessfulCheckDispatchesOnce() {
        val service = mockk<AccessibilityService>()
        val child = nativeNode(targetIdentity.copy(uniqueId = ""), targetBounds)
        val nativeRoot = nativeNode(rootIdentity, display, listOf(child))
        every { service.windows } returns listOf(nativeWindow(nativeRoot))
        var taps = 0
        val tapHandler = CheckedTapHandler { actualService, x, y ->
            assertTrue(actualService === service)
            assertEquals(40f, x)
            assertEquals(60f, y)
            taps++
            true
        }
        val actualSpec = spec.copy(identity = targetIdentity.copy(uniqueId = ""))
        val result = tapHandler.tap(service, actualSpec, display)
        assertTrue(result is CheckedTapHandler.Result.Tapped)
        assertEquals(1, taps)
        verify(exactly = 1) { nativeRoot.refresh(); child.refresh(); nativeRoot.recycle(); child.recycle() }
    }

    @Test
    fun staleOrMissingChildrenRefuseBeforeDispatchAndRecycleBorrowedNodes() {
        val service = mockk<AccessibilityService>()
        val nativeRoot = nativeNode(rootIdentity, display)
        every { service.windows } returns listOf(nativeWindow(nativeRoot))
        val tapHandler = CheckedTapHandler { _, _, _ -> error("must not dispatch") }
        every { nativeRoot.refresh() } returns false
        val stale = tapHandler.tap(service, spec, display) as CheckedTapHandler.Result.Refused
        assertEquals("node_refresh", stale.condition)
        assertTrue(stale.toJson().getString("error").contains("observed="))
        verify(exactly = 1) { nativeRoot.recycle() }
        every { nativeRoot.refresh() } returns true
        every { nativeRoot.childCount } returns 1
        every { nativeRoot.getChild(0) } returns null
        val missing = tapHandler.tap(service, spec, display) as CheckedTapHandler.Result.Refused
        assertEquals("child_available", missing.condition)
        verify(exactly = 2) { nativeRoot.recycle() }
    }

    @Test
    fun interruptedSnapshotRefusesWithoutDispatch() {
        val service = mockk<AccessibilityService>()
        every { service.windows } returns listOf(nativeWindow(nativeNode(rootIdentity, display)))
        val tapHandler = CheckedTapHandler { _, _, _ -> error("must not dispatch") }
        Thread.currentThread().interrupt()
        try {
            val result = tapHandler.tap(service, spec, display) as CheckedTapHandler.Result.Refused
            assertEquals("snapshot_deadline", result.condition)
            assertTrue(result.observed.getBoolean("interrupted"))
        } finally {
            Thread.interrupted()
        }
    }

    private fun nativeNode(identity: Identity, bounds: Bounds, children: List<AccessibilityNodeInfo> = emptyList()): AccessibilityNodeInfo {
        val node = mockk<AccessibilityNodeInfo>(relaxed = true)
        every { node.refresh() } returns true
        every { node.className } returns identity.className
        every { node.viewIdResourceName } returns identity.resourceId
        every { node.uniqueId } returns identity.uniqueId
        every { node.text } returns identity.text
        every { node.contentDescription } returns identity.contentDescription
        every { node.hintText } returns identity.hint
        every { node.isVisibleToUser } returns true
        every { node.isEnabled } returns true
        every { node.drawingOrder } returns 1
        every { node.childCount } returns children.size
        children.forEachIndexed { index, child -> every { node.getChild(index) } returns child }
        every { node.getBoundsInScreen(any()) } answers { assign(firstArg(), bounds) }
        return node
    }

    private fun nativeWindow(root: AccessibilityNodeInfo): AccessibilityWindowInfo {
        val window = mockk<AccessibilityWindowInfo>(relaxed = true)
        every { window.id } returns 1
        every { window.layer } returns 1
        every { window.root } returns root
        every { window.getBoundsInScreen(any()) } answers { assign(firstArg(), display) }
        return window
    }

    private fun assign(rect: Rect, bounds: Bounds) {
        // Android SDK Rect.set() is a no-op stub in these local JVM tests.
        rect.left = bounds.left
        rect.top = bounds.top
        rect.right = bounds.right
        rect.bottom = bounds.bottom
    }
}
