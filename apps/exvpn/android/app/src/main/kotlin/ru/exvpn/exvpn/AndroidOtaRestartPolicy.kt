package ru.exvpn.exvpn

/** Process-local lease. A new VPN start always wins over an OTA restart. */
internal class AndroidOtaRestartPolicy {
    private var session: String? = null
    val pending: Boolean get() = session != null

    fun begin(arguments: Any?, token: String, idle: Boolean, foreground: Boolean) {
        if (arguments != null || !TOKEN.matches(token)) throw AndroidUpdateFailure("invalid_request")
        if (pending) throw AndroidUpdateFailure("operation_busy")
        if (!idle || !foreground) throw AndroidUpdateFailure("restart_blocked")
        session = token
    }

    fun owns(token: String): Boolean = session == token

    fun commit(token: String, idle: Boolean): Boolean {
        if (!owns(token) || !idle) return false
        session = null
        return true
    }

    fun cancel(token: String): Boolean {
        if (!owns(token)) return false
        session = null
        return true
    }

    companion object { val TOKEN = Regex("[a-f0-9]{32}") }
}
