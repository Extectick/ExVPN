package ru.exvpn.exvpn

/** An OS-confirmed tuple owner is distinct from the routing selection. Include
 * mode needs known unselected owners too; unresolved or mixed identities stay
 * unknown so the native dispatcher keeps them inside the VPN. */
internal object ApplicationOwnerConfirmation {
    // Android full UIDs include userId * PER_USER_RANGE. Only the application
    // appId range is eligible, including in secondary/work profiles; system,
    // SDK sandbox and isolated appIds must remain protected.
    fun isApplicationUID(uid: Int): Boolean = uid >= 0 && uid % 100000 in 10000..19999

    fun confirm(uid: Int, vpnUid: Int, ownerPackages: Set<String>, mode: String,
        selectedPackages: Set<String>, resolvedSelectedUIDs: Set<Int>): Int {
        if (!isApplicationUID(uid) || uid == vpnUid || ownerPackages.isEmpty()) return -1
        if (mode != "exclude" && mode != "include") return -1
        if (uid in resolvedSelectedUIDs) {
            // A shared UID must still belong entirely to the captured selected
            // packages. UID reuse or a newly installed shared package revokes it.
            return if (selectedPackages.containsAll(ownerPackages)) uid else -1
        }
        // A selected package whose UID changed needs a fresh connection snapshot.
        if (ownerPackages.any { it in selectedPackages }) return -1
        return if (mode == "include") uid else -1
    }
}
