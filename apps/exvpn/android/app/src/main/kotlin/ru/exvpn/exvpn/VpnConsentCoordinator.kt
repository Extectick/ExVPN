package ru.exvpn.exvpn

/** Owns one platform consent request, not the tunnel. All callbacks run on the
 * activity thread. A cancelled/stale activity result must never start a VPN. */
internal class VpnConsentCoordinator<Request, Reply, Consent>(
    private val prepare: () -> Consent?,
    private val nextToken: () -> Int,
    private val launch: (Consent, Int) -> Unit,
    private val waiting: (Request) -> Unit,
    private val start: (Request, Reply) -> Unit,
    private val fail: (Request, Reply, String) -> Unit,
) {
    private data class Flight<Request, Reply>(val request: Request, val reply: Reply,
        val token: Int, var leftActivity: Boolean = false)
    private var flight: Flight<Request, Reply>? = null
    val pending: Boolean get() = flight != null

    fun connect(request: Request, reply: Reply) {
        if (pending) { fail(request, reply, "operation_in_progress"); return }
        val consent = try { prepare() } catch (_: Exception) {
            fail(request, reply, "vpn_permission_unavailable"); return
        }
        if (consent == null) { begin(request, reply); return }
        val token = try { nextToken() } catch (_: Exception) {
            fail(request, reply, "vpn_permission_unavailable"); return
        }
        val current = Flight(request, reply, token)
        flight = current
        try {
            launch(consent, token)
            // The UI says it is waiting only after Android accepted the launch.
            if (flight === current) waiting(request)
        } catch (_: Exception) {
            if (flight === current) reject("vpn_permission_unavailable")
        }
    }

    fun onActivityPaused() { flight?.leftActivity = true }

    fun onActivityResult(token: Int, granted: Boolean) {
        val current = flight ?: return
        if (current.token != token) return
        if (!granted) { reject("permission_denied"); return }
        // RESULT_OK alone is not a grant: another VPN/policy can revoke consent
        // before this callback. Never start an unprepared foreground service.
        finishIfPrepared("vpn_permission_unavailable")
    }

    /** Called once the activity is resumed AND focused again. Some devices lose
     * the result callback; a failed/no-op launch must not leave a pending state. */
    fun onFocusedForeground() {
        val current = flight ?: return
        finishIfPrepared(if (current.leftActivity) "permission_denied" else "vpn_permission_unavailable")
    }

    fun cancel(): Pair<Request, Reply>? {
        val current = flight ?: return null
        flight = null
        return current.request to current.reply
    }

    fun dispose() { if (pending) reject("permission_cancelled") }

    private fun finishIfPrepared(error: String) {
        val current = flight ?: return
        val prepared = try { prepare() == null } catch (_: Exception) { false }
        flight = null
        if (prepared) begin(current.request, current.reply)
        else fail(current.request, current.reply, error)
    }

    private fun reject(code: String) {
        val current = flight ?: return
        flight = null
        fail(current.request, current.reply, code)
    }

    private fun begin(request: Request, reply: Reply) {
        try { start(request, reply) }
        catch (_: Exception) { fail(request, reply, "native_start_failed") }
    }
}
