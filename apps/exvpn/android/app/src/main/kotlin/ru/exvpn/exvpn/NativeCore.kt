package ru.exvpn.exvpn

/** Only normalized profiles cross JNI. No subscription or arbitrary config API. */
object NativeCore {
    val available: Boolean = try { System.loadLibrary("exvpn"); true } catch (_: UnsatisfiedLinkError) { false }
    external fun validate(profile: ByteArray): String
    external fun start(service: ExVpnService, fd: Int, profile: ByteArray, endpoint: String, exclusions: IntArray, routingMode: String): String
    private external fun siteRoutingSchema(): Int
    private external fun startRouted(service: ExVpnService, fd: Int, profile: ByteArray, endpoint: String,
        exclusions: IntArray, routingMode: String, siteRouting: ByteArray): String
    fun siteRoutingSupported(): Boolean = available && try { siteRoutingSchema() == 1 } catch (_: LinkageError) { false }
    fun startWithSiteRouting(service: ExVpnService, fd: Int, profile: ByteArray, endpoint: String,
        exclusions: IntArray, routingMode: String, siteRouting: ByteArray): String = try {
        if (!siteRoutingSupported()) "site_routing_unavailable"
        else startRouted(service, fd, profile, endpoint, exclusions, routingMode, siteRouting)
    } catch (_: LinkageError) { "site_routing_unavailable" }
    external fun stop()
    external fun cancel()
    external fun health(): String
    external fun stats(): String
}
