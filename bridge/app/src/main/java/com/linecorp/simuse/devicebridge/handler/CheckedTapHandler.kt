// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge.handler

import android.accessibilityservice.AccessibilityService
import android.graphics.Rect
import android.os.Build
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.roundToInt

/** Checks a fresh accessibility snapshot on the device before dispatching the normal /tap gesture. */
class CheckedTapHandler(
    private val dispatchTap: (AccessibilityService, Float, Float) -> Boolean = GestureHandler()::tap,
) {
    data class Bounds(val left: Int, val top: Int, val right: Int, val bottom: Int) {
        fun contains(other: Bounds) = left <= other.left && top <= other.top && right >= other.right && bottom >= other.bottom
        fun contains(x: Int, y: Int) = x >= left && x < right && y >= top && y < bottom
        fun toJson() = JSONObject().put("left", left).put("top", top).put("right", right).put("bottom", bottom)
    }

    data class Ancestor(val className: String, val resourceId: String) {
        fun toJson() = JSONObject().put("className", className).put("resourceId", resourceId)
    }

    data class Identity(
        val className: String,
        val resourceId: String,
        val uniqueId: String,
        val text: String,
        val contentDescription: String,
        val hint: String,
    ) {
        fun toJson() = JSONObject().put("className", className).put("resourceId", resourceId)
            .put("uniqueId", uniqueId).put("text", text).put("contentDescription", contentDescription).put("hint", hint)
        fun ancestor() = Ancestor(className, resourceId)
    }

    data class Spec(val identity: Identity, val ancestry: List<Ancestor>, val expectedBounds: Bounds) {
        fun targetJson() = identity.toJson().put("ancestry", JSONArray().apply { ancestry.forEach { put(it.toJson()) } })

        companion object {
            fun parse(json: String): Spec {
                val objectJson = JSONObject(json)
                val target = objectJson.getJSONObject("target")
                fun string(objectValue: JSONObject, name: String): String =
                    objectValue.get(name) as? String ?: throw IllegalArgumentException("$name must be a string")
                val identity = Identity(
                    string(target, "className"), string(target, "resourceId"), string(target, "uniqueId"),
                    string(target, "text"), string(target, "contentDescription"), string(target, "hint"),
                )
                require(identity.className.isNotEmpty()) { "target.className must not be empty" }
                val ancestors = target.getJSONArray("ancestry")
                require(ancestors.length() <= MAX_DEPTH) { "target.ancestry is too deep" }
                val ancestry = (0 until ancestors.length()).map {
                    val ancestor = ancestors.getJSONObject(it)
                    val className = string(ancestor, "className")
                    require(className.isNotEmpty()) { "ancestor.className must not be empty" }
                    Ancestor(className, string(ancestor, "resourceId"))
                }
                val bounds = objectJson.getJSONObject("expectedBounds")
                fun coordinate(name: String): Int {
                    // getInt silently coerces strings and fractions; checked input must be exact.
                    val value = bounds.get(name)
                    require(value is Number && value.toDouble().isFinite() && value.toDouble() == value.toInt().toDouble()) {
                        "expectedBounds.$name must be an Int32"
                    }
                    return value.toInt()
                }
                val expected = Bounds(coordinate("left"), coordinate("top"), coordinate("right"), coordinate("bottom"))
                require(expected.right > expected.left && expected.bottom > expected.top) { "expectedBounds must have positive area" }
                return Spec(identity, ancestry, expected)
            }
        }
    }

    internal data class Node(
        val identity: Identity,
        val bounds: Bounds,
        val visible: Boolean,
        val enabled: Boolean,
        val drawingOrder: Int,
        val children: List<Node> = emptyList(),
    )

    internal data class Window(val id: Int, val layer: Int, val bounds: Bounds, val root: Node?)
    internal data class Checked(val x: Int, val y: Int)

    sealed interface Result {
        data class Tapped(val data: JSONObject) : Result
        data class Refused(val condition: String, val expected: JSONObject, val observed: JSONObject) : Result {
            fun toJson(): JSONObject {
                val detail = "$condition: expected=$expected observed=$observed"
                return JSONObject().put("status", "error").put("code", "checked_tap_refused")
                    .put("condition", condition).put("expected", expected).put("observed", observed)
                    .put("error", detail).put("message", detail)
            }
        }
    }

    private class Rejected(val result: Result.Refused) : RuntimeException(result.condition)

    fun tap(service: AccessibilityService, spec: Spec, display: Bounds): Result {
        val started = System.nanoTime()
        return try {
            val windows = capture(service, started)
            val checked = check(spec, windows, display)
            // Synchronous by design: no cancelled executor task may dispatch a late tap.
            ensureBudget(started)
            if (!dispatchTap(service, checked.x.toFloat(), checked.y.toFloat())) {
                reject("gesture_dispatch", JSONObject().put("accepted", true), JSONObject().put("accepted", false))
            }
            Result.Tapped(JSONObject().put("x", checked.x).put("y", checked.y)
                .put("target", spec.targetJson()).put("bounds", spec.expectedBounds.toJson()))
        } catch (rejected: Rejected) {
            rejected.result
        } catch (error: Exception) {
            Result.Refused("tree_unavailable", JSONObject().put("snapshot", "complete"),
                JSONObject().put("error", error.message ?: error.javaClass.simpleName))
        }
    }

    internal fun check(spec: Spec, windows: List<Window>, display: Bounds): Checked {
        data class Candidate(val node: Node, val window: Window, val ancestors: List<Node>)
        val matches = mutableListOf<Candidate>()
        fun find(node: Node, window: Window, ancestors: List<Node>) {
            if (node.identity == spec.identity && ancestors.map { it.identity.ancestor() } == spec.ancestry) {
                matches.add(Candidate(node, window, ancestors))
            }
            node.children.forEach { find(it, window, ancestors + node) }
        }
        if (windows.isEmpty()) reject("windows_available", JSONObject().put("minimum", 1), JSONObject().put("count", 0))
        windows.forEach { window ->
            val root = window.root ?: reject("window_root_available", JSONObject().put("root", "available"),
                JSONObject().put("windowId", window.id).put("layer", window.layer).put("root", JSONObject.NULL))
            find(root, window, emptyList())
        }
        if (matches.size != 1) reject("unique_match", JSONObject().put("count", 1).put("target", spec.targetJson()),
            JSONObject().put("count", matches.size))
        val target = matches.single()
        val bounds = target.node.bounds
        if (bounds != spec.expectedBounds) reject("unchanged_bounds", spec.expectedBounds.toJson(), bounds.toJson())
        val chain = target.ancestors + target.node
        chain.forEachIndexed { index, node ->
            if (!node.visible || !node.enabled) reject("visible_enabled_chain",
                JSONObject().put("visible", true).put("enabled", true), node.identity.toJson()
                    .put("chainIndex", index).put("visible", node.visible).put("enabled", node.enabled))
        }
        if (!display.contains(bounds)) reject("display_bounds", display.toJson(), bounds.toJson())
        if (!target.window.bounds.contains(bounds)) reject("window_bounds", target.window.bounds.toJson(), bounds.toJson())
        target.ancestors.forEachIndexed { index, ancestor ->
            if (!ancestor.bounds.contains(bounds)) reject("ancestor_bounds", ancestor.bounds.toJson().put("chainIndex", index), bounds.toJson())
        }
        val x = ((bounds.left.toDouble() + bounds.right) / 2).roundToInt()
        val y = ((bounds.top.toDouble() + bounds.bottom) / 2).roundToInt()
        if (!bounds.contains(x, y)) reject("tap_point_inside_target", bounds.toJson(), JSONObject().put("x", x).put("y", y))
        // Accessibility does not expose clipChildren. A visible descendant may extend
        // outside its parent's bounds, so do not prune that potentially covering branch.
        fun coversPoint(node: Node): Boolean = node.visible &&
            (node.bounds.contains(x, y) || node.children.any { coversPoint(it) })
        val coveringWindows = windows.filter { it.bounds.contains(x, y) || it.root?.let(::coversPoint) == true }
        val highestLayer = coveringWindows.maxOf { it.layer }
        val topWindows = coveringWindows.filter { it.layer == highestLayer }
        if (topWindows.size != 1) reject("window_layer_unambiguous", JSONObject().put("count", 1),
            JSONObject().put("layer", highestLayer).put("count", topWindows.size).put("windows", JSONArray().apply {
                coveringWindows.forEach { put(JSONObject().put("id", it.id).put("layer", it.layer)) }
            }))
        val topWindow = topWindows.single()
        if (topWindow.id != target.window.id) reject("topmost_window", JSONObject().put("windowId", target.window.id),
            JSONObject().put("windowId", topWindow.id).put("layer", topWindow.layer))
        fun hit(node: Node): Node {
            if (!node.visible || !node.bounds.contains(x, y)) reject("window_hit_available",
                JSONObject().put("visible", true).put("x", x).put("y", y),
                node.identity.toJson().put("visible", node.visible).put("bounds", node.bounds.toJson()))
            // Enabled is deliberately not a filter: disabled siblings can still cover the target.
            val children = node.children.filter(::coversPoint)
            if (children.isEmpty()) return node
            val unknownOrder = children.firstOrNull { it.drawingOrder < 0 }
            if (unknownOrder != null) reject("drawing_order_unambiguous", JSONObject().put("minimumOrder", 0),
                unknownOrder.identity.toJson().put("drawingOrder", unknownOrder.drawingOrder))
            val order = children.maxOf { it.drawingOrder }
            val topChildren = children.filter { it.drawingOrder == order }
            if (topChildren.size != 1) reject("drawing_order_unambiguous",
                JSONObject().put("count", 1).put("minimumOrder", 0),
                JSONObject().put("drawingOrder", order).put("count", topChildren.size).put("parent", node.identity.toJson()))
            return hit(topChildren.single())
        }
        val top = hit(topWindow.root!!)
        fun within(node: Node): Boolean = node === top || node.children.any { within(it) }
        if (!within(target.node)) reject("topmost_node", spec.targetJson().put("drawingOrder", target.node.drawingOrder),
            top.identity.toJson().put("bounds", top.bounds.toJson()).put("drawingOrder", top.drawingOrder).put("windowLayer", topWindow.layer))
        return Checked(x, y)
    }

    private fun capture(service: AccessibilityService, started: Long): List<Window> {
        var count = 0
        fun read(node: AccessibilityNodeInfo, depth: Int): Node {
            try {
                ensureBudget(started)
                count++
                if (count > MAX_NODES || depth > MAX_DEPTH) reject("snapshot_limit",
                    JSONObject().put("maxNodes", MAX_NODES).put("maxDepth", MAX_DEPTH),
                    JSONObject().put("nodes", count).put("depth", depth))
                if (!node.refresh()) reject("node_refresh", JSONObject().put("current", true), JSONObject().put("current", false))
                val bounds = Rect().also(node::getBoundsInScreen)
                val identity = Identity(node.className?.toString() ?: "", node.viewIdResourceName ?: "",
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) node.uniqueId ?: "" else "",
                    node.text?.toString() ?: "", node.contentDescription?.toString() ?: "", node.hintText?.toString() ?: "")
                val children = (0 until node.childCount).map { index ->
                    val child = node.getChild(index) ?: reject("child_available", JSONObject().put("child", "available"),
                        JSONObject().put("index", index).put("parent", identity.toJson()))
                    read(child, depth + 1)
                }
                return Node(identity, Bounds(bounds.left, bounds.top, bounds.right, bounds.bottom),
                    node.isVisibleToUser, node.isEnabled, node.drawingOrder, children)
            } finally {
                recycle(node)
            }
        }
        val windows = service.windows ?: emptyList()
        try {
            return windows.map { window ->
                ensureBudget(started)
                val bounds = Rect().also(window::getBoundsInScreen)
                Window(window.id, window.layer, Bounds(bounds.left, bounds.top, bounds.right, bounds.bottom),
                    window.root?.let { read(it, 0) })
            }
        } finally {
            @Suppress("DEPRECATION")
            windows.forEach { try { it.recycle() } catch (_: Exception) {} }
        }
    }

    private fun ensureBudget(started: Long) {
        val elapsed = (System.nanoTime() - started) / 1_000_000
        if (Thread.currentThread().isInterrupted || elapsed >= MAX_CAPTURE_MILLIS) reject("snapshot_deadline",
            JSONObject().put("maxMillis", MAX_CAPTURE_MILLIS).put("interrupted", false),
            JSONObject().put("elapsedMillis", elapsed).put("interrupted", Thread.currentThread().isInterrupted))
    }

    private fun reject(condition: String, expected: JSONObject, observed: JSONObject): Nothing =
        throw Rejected(Result.Refused(condition, expected, observed))

    @Suppress("DEPRECATION")
    private fun recycle(node: AccessibilityNodeInfo) { try { node.recycle() } catch (_: Exception) {} }

    companion object {
        private const val MAX_DEPTH = 256
        private const val MAX_NODES = 10_000
        private const val MAX_CAPTURE_MILLIS = 5_000L
    }
}
