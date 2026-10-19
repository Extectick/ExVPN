package ru.exvpn.exvpn

/** No endpoint or socket authority: only a bounded index over a user-selected
 * group. The service retains its TUN while scheduling the next attempt. */
internal class AutomaticSelectionPolicy(private val count: Int, initialIndex: Int) {
    init { require(count in 1..32 && initialIndex in 0 until count) }
    companion object {
        fun retryable(code: String): Boolean = code in setOf(
            "network_unavailable", "endpoint_resolution_failed",
            "tunnel_https_failed", "tunnel_https_status")
    }
    data class Next(val index: Int, val delayMillis: Long)
    private var index = initialIndex
    private var failures = 0
    fun succeeded() { failures = 0 }
    fun failed(): Next {
        index = (index + 1) % count
        failures++
        val exhausted = failures >= count
        if (exhausted) failures = 0
        return Next(index, if (exhausted) 30_000L else 2_000L)
    }
}
