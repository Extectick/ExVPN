package ru.exvpn.exvpn

import org.json.JSONArray
import org.json.JSONObject

/** A bounded, fixed-schema local record, separate from the subscription/profile. */
internal object SiteRoutingJson {
    fun encode(state: SiteRoutingState): JSONObject = JSONObject(state.wire()).also {
        require(it.toString().toByteArray(Charsets.UTF_8).size <= SiteRoutingState.MAX_BYTES)
    }

    fun decode(record: JSONObject): SiteRoutingState {
        require(record.toString().toByteArray(Charsets.UTF_8).size <= SiteRoutingState.MAX_BYTES)
        return SiteRoutingState.fromWire(wireValue(record, 0))
    }

    private fun wireValue(value: Any?, depth: Int): Any? {
        require(depth <= 6)
        return when (value) {
            is JSONObject -> {
                require(value.length() <= 4)
                value.keys().asSequence().associateWith { wireValue(value.get(it), depth + 1) }
            }
            is JSONArray -> {
                require(value.length() <= 2048)
                (0 until value.length()).map { wireValue(value.get(it), depth + 1) }
            }
            is String, is Int -> value
            else -> throw IllegalArgumentException()
        }
    }
}
