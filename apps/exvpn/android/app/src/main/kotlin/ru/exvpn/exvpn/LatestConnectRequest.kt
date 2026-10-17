package ru.exvpn.exvpn

/** The service may receive an empty duplicate intent after a newer request has
 * already been consumed. Keep that request until it is replaced or stopped. */
internal class LatestConnectRequest<T : Any> {
    @Volatile var current: T? = null
        private set

    fun accept(next: T?) {
        if (next != null) current = next
    }

    fun clear() { current = null }
}
