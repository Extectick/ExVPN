package ru.exvpn.exvpn

internal class AndroidUpdateFailure(val code: String) : Exception(code)
internal data class AndroidInstallRequest(val version: String, val build: Long, val sha256: String) {
    companion object {
        val semver = Regex("(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})")
        fun parse(raw: Any?): AndroidInstallRequest {
            val map = raw as? Map<*, *> ?: throw AndroidUpdateFailure("invalid_request")
            if (map.keys != setOf("version", "build", "sha256")) throw AndroidUpdateFailure("invalid_request")
            val version = map["version"] as? String ?: throw AndroidUpdateFailure("invalid_request")
            val build = when (val value = map["build"]) { is Int -> value.toLong(); is Long -> value; else -> throw AndroidUpdateFailure("invalid_request") }
            val sha = map["sha256"] as? String ?: throw AndroidUpdateFailure("invalid_request")
            if (!semver.matches(version) || build !in 1..2147483647L || !Regex("[a-f0-9]{64}").matches(sha)) throw AndroidUpdateFailure("invalid_request")
            return AndroidInstallRequest(version, build, sha)
        }
    }
}
internal data class AndroidPackageIdentity(val packageName: String, val version: String, val build: Long,
    val minSdk: Int, val signers: Set<String>)

/** This pin is independent of the Dart signed-manifest verifier. */
internal object AndroidUpdatePolicy {
    const val SIGNER = "2a43b65b5261da825b1793e8d9a2196b868fa0887b2e87c5908298b4ccbc7093"
    const val PACKAGE = "ru.exvpn.exvpn"
    const val MAX_BYTES = 512L * 1024 * 1024
    fun validate(request: AndroidInstallRequest, installed: AndroidPackageIdentity, archive: AndroidPackageIdentity, sdk: Int) {
        if (installed.packageName != PACKAGE || archive.packageName != PACKAGE || archive.version != request.version || archive.build != request.build) throw AndroidUpdateFailure("apk_invalid")
        if (installed.signers != setOf(SIGNER) || archive.signers != setOf(SIGNER)) throw AndroidUpdateFailure("signature_invalid")
        if (!AndroidInstallRequest.semver.matches(installed.version) || archive.build <= installed.build || archive.minSdk > sdk || archive.minSdk < 1) throw AndroidUpdateFailure("apk_incompatible")
        val current = installed.version.split('.').map(String::toInt)
        val target = archive.version.split('.').map(String::toInt)
        for (index in 0..2) {
            if (target[index] < current[index]) throw AndroidUpdateFailure("apk_incompatible")
            if (target[index] > current[index]) break
        }
    }
}
