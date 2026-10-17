package ru.exvpn.exvpn

/** Local policy only. Disabled deliberately retains the remembered selection. */
internal data class ApplicationRoutingPolicy(val mode: String, val applications: Set<String>) {
    init {
        require(mode == "disabled" || mode == "exclude" || mode == "include")
        require(applications.size <= 500 && applications.all {
            it.length <= 255 && it.matches(Regex("[a-zA-Z0-9_]+(\\.[a-zA-Z0-9_]+)+"))
        })
    }
    fun wire(): Map<String, Any> = mapOf("mode" to mode, "applications" to applications.sorted())
    companion object {
        fun legacy(applications: Set<String>) = ApplicationRoutingPolicy(
            if (applications.isEmpty()) "disabled" else "exclude", applications.toSet())
        fun fromWire(value: Any?): ApplicationRoutingPolicy {
            val fields = value as? Map<*, *> ?: throw IllegalArgumentException()
            require(fields.keys == setOf("mode", "applications"))
            val mode = fields["mode"] as? String ?: throw IllegalArgumentException()
            val values = fields["applications"] as? List<*> ?: throw IllegalArgumentException()
            require(values.size <= 128 && values.all { it is String })
            val ids = values.map { it as String }.toSet()
            require(ids.size == values.size)
            return ApplicationRoutingPolicy(mode, ids)
        }
    }
}
