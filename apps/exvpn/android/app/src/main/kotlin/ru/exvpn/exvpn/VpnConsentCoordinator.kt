package ru.exvpn.exvpn

/** Permission failure cannot create a tunnel. Report an authoritative idle
 * state only when BOTH native owners are confirmed absent; existing/unknown
 * ownership must retain the controller's conservative protection state. */
internal data class VpnConsentFailureState(val phase: String, val profileId: String?) {
    companion object {
        fun resolve(profileId: String, servicePresent: Boolean?, requestPending: Boolean?): VpnConsentFailureState =
            if (servicePresent == false && requestPending == false) VpnConsentFailureState("disconnected", null)
            else VpnConsentFailureState("error", profileId)
    }
}

/** Owns one platform consent request, not the tunnel. All callbacks run on the
 * activity thread. A cancelled/stale activity result must never start a VPN. */
internal class VpnConsentCoordinator<Request, Reply, Consent>(
    private val prepare: () -> Consent?,
    private val nextToken: () -> Int,
    private val launch: (Consent, Int) -> Unit,
    private val waiting: (Request) -> Unit,
    private val start: (Request, Reply) -> Unit,
    private val fail: (Request, Reply, String) -> Unit,
    private val isForeground: () -> Boolean = { true },
) {
    private data class Flight<Request, Reply>(val request: Request, val reply: Reply,
        var token: Int? = null)
    private var flight: Flight<Request, Reply>? = null
    private var paused = false
    val pending: Boolean get() = flight != null
    private fun foreground() = !paused && isForeground()

    fun connect(request: Request, reply: Reply) {
        if (pending) { fail(request, reply, "operation_in_progress"); return }
        flight = Flight(request, reply)
        advance()
    }

    /** A connect may arrive while the activity is returning from another system
     * window. Keep the explicit request, but never launch consent or the service
     * until the activity is actually resumed and focused. */
    private fun advance() {
        val current = flight ?: return
        if (!foreground()) return
        if (current.token != null) {
            completeIfPrepared()
            return
        }
        val consent = try { prepare() } catch (_: Exception) {
            reject("vpn_permission_unavailable"); return
        }
        if (consent == null) { complete(current); return }
        val token = try { nextToken() } catch (_: Exception) {
            reject("vpn_permission_unavailable"); return
        }
        current.token = token
        try {
            launch(consent, token)
            // The UI says it is waiting only after Android accepted the launch.
            if (flight === current) waiting(current.request)
        } catch (_: Exception) {
            if (flight === current) reject("vpn_permission_unavailable")
        }
    }

    fun onActivityPaused() { paused = true }

    fun onActivityResult(token: Int, granted: Boolean) {
        val current = flight ?: return
        if (current.token != token) return
        // prepare(), not the result code or a lifecycle transition, is the
        // authority. A real cancellation with no grant settles as a denial;
        // RESULT_OK with a revoked/missing grant is an unavailable permission.
        val prepared = try { prepare() == null } catch (_: Exception) {
            reject("vpn_permission_unavailable"); return
        }
        if (!prepared) {
            reject(if (granted) "vpn_permission_unavailable" else "permission_denied")
            return
        }
        // Android delivers results before onResume on some versions. The next
        // focused resume rechecks prepare() before starting the service.
        if (foreground()) complete(current)
    }

    /** Called once the activity is resumed AND focused again. Some devices lose
     * the result callback. A focus event alone is never evidence of denial. */
    fun onFocusedForeground() { paused = false; advance() }

    /** Only a continuous, focused foreground grace period may settle a missing
     * callback/no-op launch. This is unavailability, never a claimed user denial.
     * The activity cancels this guard while a real system dialog is on screen. */
    fun onForegroundTimeout() {
        if (flight == null || !foreground()) return
        if (!completeIfPrepared()) reject("vpn_permission_unavailable")
    }

    fun cancel(): Pair<Request, Reply>? {
        val current = flight ?: return null
        flight = null
        return current.request to current.reply
    }

    fun dispose() { if (pending) reject("permission_cancelled") }

    private fun completeIfPrepared(): Boolean {
        val current = flight ?: return false
        val prepared = try { prepare() == null } catch (_: Exception) {
            reject("vpn_permission_unavailable"); return false
        }
        if (prepared && foreground()) complete(current)
        return prepared
    }

    private fun complete(current: Flight<Request, Reply>) {
        if (flight !== current) return
        flight = null
        begin(current.request, current.reply)
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
