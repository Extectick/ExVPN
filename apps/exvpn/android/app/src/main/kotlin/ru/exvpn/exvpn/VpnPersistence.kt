package ru.exvpn.exvpn

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class NativeStoreFailure : Exception("native_storage_unavailable")

/** Native service recovery is independent of Flutter/Activity lifetime.
 * All operations share this process lock: AtomicFile does not lock itself.
 * Only encrypted records enter noBackupFilesDir; keys stay in Android Keystore.
 * A bad/absent key for existing ciphertext fails closed, never resets the data.
 */
internal object VpnPersistence {
    private const val MAX_BYTES = 1_200_000
    private const val KEYSTORE = "AndroidKeyStore"
    private const val POLICY = "policy"
    private const val RESUME = "resume"
    private const val SITE_ROUTING = "site_routing"

    @Synchronized fun loadPolicy(context: Context): Set<String> = guarded {
        val policy = loadApplicationRouting(context)
        if (policy.mode == "exclude") policy.applications else emptySet()
    }

    @Synchronized fun savePolicy(context: Context, selected: Set<String>) = guarded {
        saveApplicationRouting(context, ApplicationRoutingPolicy.legacy(selected))
    }

    @Synchronized fun loadApplicationRouting(context: Context): ApplicationRoutingPolicy = guarded {
        val record = read(context, POLICY) ?: return@guarded ApplicationRoutingPolicy.legacy(emptySet())
        val selected = packages(record.getJSONArray("packages"))
        if (record.getInt("schema") == 1) {
            require(record.length() == 2)
            ApplicationRoutingPolicy.legacy(selected)
        } else {
            require(record.getInt("schema") == 2 && record.length() == 3)
            ApplicationRoutingPolicy(record.getString("mode"), selected)
        }
    }

    @Synchronized fun saveApplicationRouting(context: Context, policy: ApplicationRoutingPolicy) = guarded {
        val checked = packages(JSONArray(policy.applications.sorted()))
        write(context, POLICY, JSONObject().put("schema", 2).put("mode", policy.mode)
            .put("packages", JSONArray(checked.sorted())))
    }

    @Synchronized fun loadSiteRouting(context: Context): SiteRoutingState = guarded {
        // The Keystore alias is created before the first atomic write and is
        // never removed. A lost record must not turn a previous include policy
        // into the fresh-install disabled policy.
        val record = read(context, SITE_ROUTING) ?: return@guarded SiteRoutingRecovery.absent(
            KeyStore.getInstance(KEYSTORE).apply { load(null) }.containsAlias(alias(SITE_ROUTING)))
        SiteRoutingJson.decode(record)
    }

    @Synchronized fun saveSiteRouting(context: Context, state: SiteRoutingState) = guarded {
        // Reject semantically malformed existing state before any replacement.
        loadSiteRouting(context)
        write(context, SITE_ROUTING, SiteRoutingJson.encode(state))
    }

    @Synchronized fun loadResume(context: Context): ConnectRequest? = guarded {
        val record = read(context, RESUME) ?: return@guarded null
        val schema = record.getInt("schema")
        require((schema == 1 && record.length() == 3) || (schema == 2 && record.length() == 4) ||
            (schema == 3 && record.length() == 5) || (schema == 4 && record.length() == 6))
        val profile = record.getString("profile")
        require(profile.toByteArray(Charsets.UTF_8).size <= 1_048_576)
        val id = JSONObject(profile).getString("id")
        require(id.isNotEmpty() && id.length <= 4096)
        val selected = packages(record.getJSONArray("packages"))
        val policy = if (schema == 1) ApplicationRoutingPolicy.legacy(selected)
            else ApplicationRoutingPolicy(record.getString("mode"), selected)
        val automatic = if (schema >= 3) automaticProfiles(record.getJSONArray("automaticProfiles"), profile) else emptyList()
        val currentSites = loadSiteRouting(context)
        val sites = if (schema == 4) SiteRoutingJson.decode(record.getJSONObject("siteRouting")) else currentSites
        require(sites.policy == currentSites.policy)
        ConnectRequest(profile, id, policy.applications, policy.mode, automatic, sites)
    }

    @Synchronized fun saveResume(context: Context, request: ConnectRequest) = guarded {
        require(request.profile.toByteArray(Charsets.UTF_8).size <= 1_048_576)
        require(JSONObject(request.profile).getString("id") == request.profileId)
        val selected = packages(JSONArray(request.packages.sorted()))
        val policy = ApplicationRoutingPolicy(request.routingMode, selected)
        val automatic = automaticProfiles(JSONArray(request.automaticProfiles), request.profile)
        val sites = SiteRoutingJson.encode(request.siteRouting)
        write(context, RESUME, JSONObject().put("schema", 4).put("mode", policy.mode)
            .put("profile", request.profile).put("packages", JSONArray(selected.sorted()))
            .put("automaticProfiles", JSONArray(automatic)).put("siteRouting", sites))
    }

    @Synchronized fun clearResume(context: Context) = guarded {
        val file = atomicFile(context, RESUME)
        file.delete()
        // Explicit stop must not leave a recoverable old session, including
        // AtomicFile's legacy backup or unfinished replacement.
        require(listOf("", ".bak", ".new").none { File(file.baseFile.path + it).exists() })
    }

    private fun automaticProfiles(array: JSONArray, selectedProfile: String): List<String> {
        require(array.length() <= 32)
        val ids = mutableSetOf<String>()
        var bytes = 0
        val result = (0 until array.length()).map { index ->
            val value = array.get(index)
            require(value is String)
            bytes += value.toByteArray(Charsets.UTF_8).size
            require(bytes <= 1_048_576)
            val id = JSONObject(value).getString("id")
            require(id.isNotEmpty() && id.length <= 4096 && ids.add(id))
            value
        }
        require(result.isEmpty() || result.any { NativeProfileIdentity.equivalent(it, selectedProfile) })
        return result
    }

    private fun packages(array: JSONArray): Set<String> {
        require(array.length() <= 500)
        val result = mutableSetOf<String>()
        for (index in 0 until array.length()) {
            val name = array.get(index)
            require(name is String && name.length <= 255 &&
                name.matches(Regex("[a-zA-Z0-9_]+(\\.[a-zA-Z0-9_]+)+")))
            require(result.add(name))
        }
        return result.toSet()
    }

    private fun atomicFile(context: Context, kind: String): AtomicFile =
        AtomicFile(File(context.noBackupFilesDir, "exvpn_native_$kind.v1"))

    private fun alias(kind: String) = "ru.exvpn.native.$kind.v1"
    private fun key(kind: String, create: Boolean): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        val existing = store.getKey(alias(kind), null)
        if (existing != null) return existing as SecretKey
        require(create)
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).run {
            init(KeyGenParameterSpec.Builder(alias(kind), KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
            generateKey()
        }
    }

    private fun read(context: Context, kind: String): JSONObject? {
        val file = atomicFile(context, kind)
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return null
        val bytes = file.openRead().use { input ->
            require(input.channel.size() in 29L..MAX_BYTES.toLong())
            input.readBytes().also { require(it.size in 29..MAX_BYTES) }
        }
        require(bytes[0] == 1.toByte())
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(kind, false), GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
        cipher.updateAAD(alias(kind).toByteArray(Charsets.UTF_8))
        val plain = cipher.doFinal(bytes, 13, bytes.size - 13)
        return try {
            val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(plain)).toString()
            JSONObject(text)
        } finally { plain.fill(0) }
    }

    private fun write(context: Context, kind: String, record: JSONObject) {
        // Do not replace unreadable existing data with a new key/empty policy.
        read(context, kind)
        val plain = record.toString().toByteArray(Charsets.UTF_8)
        try {
            require(plain.size + 29 <= MAX_BYTES)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key(kind, true))
            cipher.updateAAD(alias(kind).toByteArray(Charsets.UTF_8))
            require(cipher.iv.size == 12)
            val encrypted = byteArrayOf(1) + cipher.iv + cipher.doFinal(plain)
            val file = atomicFile(context, kind)
            val stream = file.startWrite()
            try {
                stream.write(encrypted)
                stream.fd.sync()
                file.finishWrite(stream)
            } catch (error: Exception) {
                file.failWrite(stream)
                throw error
            }
            // AtomicFile can log rather than throw a failed rename; verify the
            // exact encrypted bytes before acknowledging durable policy.
            require(file.openRead().use { it.readBytes() }.contentEquals(encrypted))
        } finally { plain.fill(0) }
    }

    private inline fun <T> guarded(action: () -> T): T = try { action() }
    catch (_: Exception) { throw NativeStoreFailure() }
}
