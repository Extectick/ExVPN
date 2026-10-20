package ru.exvpn.exvpn

/** Initialization evidence lives in the independent Android Keystore alias. */
internal object SiteRoutingRecovery {
    fun absent(initialized: Boolean): SiteRoutingState {
        check(!initialized) { "native_storage_unavailable" }
        return SiteRoutingState.default()
    }
}

/** No usable cached policy survives an unconfirmed durable operation. */
internal class SiteRoutingSnapshot {
    @Volatile private var current: SiteRoutingState? = null

    fun capture(): SiteRoutingState = checkNotNull(current) { "native_storage_unavailable" }.snapshot()

    fun reload(read: () -> SiteRoutingState) {
        current = null
        current = read().snapshot()
    }

    fun save(requested: SiteRoutingState, write: (SiteRoutingState) -> Unit) {
        current = null
        val captured = requested.snapshot()
        write(captured)
        current = captured
    }
}
