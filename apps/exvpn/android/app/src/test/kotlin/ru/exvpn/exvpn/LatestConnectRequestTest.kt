package ru.exvpn.exvpn

import org.junit.Assert.*
import org.junit.Test

class LatestConnectRequestTest {
    @Test fun emptyDuplicateIntentKeepsLatestReplacement() {
        val requests = LatestConnectRequest<Any>()
        val first = Any()
        val latest = Any()
        requests.accept(first)
        requests.accept(latest)
        requests.accept(null)
        assertSame(latest, requests.current)
    }

    @Test fun explicitStopClearsReplacementUntilANewRequestArrives() {
        val requests = LatestConnectRequest<Any>()
        requests.accept(Any())
        requests.clear()
        requests.accept(null)
        assertNull(requests.current)
        val fresh = Any()
        requests.accept(fresh)
        assertSame(fresh, requests.current)
    }
}
