package ru.exvpn.exvpn

import org.json.JSONArray
import org.json.JSONObject

/** Structural JSON equality after native validation. An ID alone cannot
 * substitute a different endpoint/credential into an automatic group. */
internal object NativeProfileIdentity {
    fun equivalent(left: String, right: String): Boolean = equal(JSONObject(left), JSONObject(right))
    private fun equal(left: Any?, right: Any?): Boolean {
        if (left is JSONObject && right is JSONObject) {
            val keys = left.keys().asSequence().toSet()
            return keys == right.keys().asSequence().toSet() && keys.all { equal(left.get(it), right.get(it)) }
        }
        if (left is JSONArray && right is JSONArray) {
            return left.length() == right.length() && (0 until left.length()).all { equal(left.get(it), right.get(it)) }
        }
        return left == right
    }
}
