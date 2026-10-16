package ru.exvpn.exvpn

/** Only normalized profiles cross JNI. No subscription or arbitrary config API. */
object NativeCore {
    val available: Boolean = try { System.loadLibrary("exvpn"); true } catch (_: UnsatisfiedLinkError) { false }
    external fun validate(profile: ByteArray): String
    external fun start(service: ExVpnService, fd: Int, profile: ByteArray, endpoint: String, exclusions: IntArray): String
    external fun stop()
    external fun cancel()
    external fun health(): String
    external fun stats(): String
}
