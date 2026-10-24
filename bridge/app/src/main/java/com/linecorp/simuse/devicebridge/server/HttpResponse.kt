// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge.server

/**
 * Minimal HTTP response value. The router builds these and the server
 * writes them to the socket. Verbatim from csat — kept identical so
 * future cross-checks against csat stay frictionless.
 */
data class HttpResponse(
    val statusCode: Int,
    val body: String,
    /** Extra response headers, e.g. `X-Simuse-Perf`. */
    val headers: Map<String, String> = emptyMap(),
)