package app.bilight.android.core

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Session bytes never enter SharedPreferences, backups, logs or another application's cookie store. */
interface SecureStore { fun load(): ByteArray?; fun save(bytes: ByteArray); fun clear() }
class SessionVault(context: Context, private val name: String = "session"): SecureStore {
    init { require(Regex("^[a-z0-9-]+$").matches(name)) }
    private val file = AtomicFile(File(context.noBackupFilesDir, "$name.enc"))
    private val alias = "app.bilight.android.$name.v1"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }
    @Synchronized override fun load(): ByteArray? {
        if (!file.baseFile.exists()) return null
        val bytes = file.readFully(); if (bytes.size < 29) invalid("保存的登录信息已损坏，请重新登录。")
        return Cipher.getInstance("AES/GCM/NoPadding").run { init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0,12))); if (name != "session") updateAAD(name.toByteArray()); doFinal(bytes.copyOfRange(12,bytes.size)) }
    }
    @Synchronized override fun save(bytes: ByteArray) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        if (name != "session") cipher.updateAAD(name.toByteArray())
        val output = file.startWrite()
        try { output.write(cipher.iv + cipher.doFinal(bytes)); file.finishWrite(output) } catch (e: Exception) { file.failWrite(output); throw e }
    }
    @Synchronized override fun clear() { file.delete(); KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(alias) }
}
