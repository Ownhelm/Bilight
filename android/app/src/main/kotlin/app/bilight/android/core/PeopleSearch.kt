package app.bilight.android.core

import me.majiajie.tinypinyin.Pinyin
import androidx.compose.runtime.*
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.text.Normalizer
import java.util.Locale

/** The snapshot is encrypted by its UID-specific SessionVault; incomplete refreshes never replace it. */
internal class PeopleSearch(private val romanize: (String) -> String = ::pinyin) {
    var keyword by mutableStateOf("")
    var items by mutableStateOf<List<User>?>(null); private set
    var busy by mutableStateOf(false); private set
    var complete by mutableStateOf(false); private set
    var error by mutableStateOf<String?>(null); private set
    private var terms = emptyMap<Long,NameTerms>()
    private var restored = false
    private data class NameTerms(val name: String, val pinyin: String, val initials: String)
    private fun index(values: List<User>) = values.associate { user ->
        val separated=user.name.replace(Regex("(?<=\\p{IsHan})(?=[A-Za-z])|(?<=[A-Za-z])(?=\\p{IsHan})")," ")
        val syllables=phonetic(romanize(separated)).split(Regex("\\s+")).filter(String::isNotEmpty)
        user.mid to NameTerms(normalize(user.name),syllables.joinToString(""),syllables.joinToString("") { it.take(1) })
    }
    private suspend fun publish(values: List<User>) {
        val prepared=withContext(Dispatchers.Default) { index(values) }
        currentCoroutineContext().ensureActive()
        terms=prepared; items=values
    }
    suspend fun restore(uid: Long,store: SecureStore) {
        if (restored) return
        restored=true
        try {
            val values=withContext(Dispatchers.IO) { store.load()?.let { decode(uid,it) } } ?: return
            publish(values); complete=true
        } catch (e: CancellationException) { throw e } catch (_: Exception) { /* A failed local read falls back to the real account refresh. */ }
    }
    suspend fun refresh(uid: Long,store: SecureStore,read: suspend (Int) -> Page<User>) {
        if (busy) return
        busy=true; error=null
        val previous=items
        try {
            val people=linkedMapOf<Long,User>()
            withTimeout(90000) {
                for (page in 1..500) {
                    val value=read(page)
                    currentCoroutineContext().ensureActive()
                    val before=people.size
                    value.items.forEach { user ->
                        if (user.mid<=0 || user.name.isBlank()) invalid()
                        people.putIfAbsent(user.mid,user)
                    }
                    if (!value.more) {
                        val values=people.values.toList()
                        val bytes=withContext(Dispatchers.Default) { encode(uid,values) }
                        withContext(Dispatchers.IO) { store.save(bytes) }
                        publish(values); complete=true
                        return@withTimeout
                    }
                    if (people.size==before) invalid("关注名单未能完整读取，请重试。")
                    // The first visible page is useful immediately while the rest is read silently.
                    if (previous==null && page==1) { publish(people.values.toList()); complete=false }
                    if (page==500) invalid("关注名单未能完整读取，请重试。")
                }
            }
        } catch (_: TimeoutCancellationException) { error="关注名单更新超时，请重试。" }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) { error=e.message ?: "关注名单更新失败，请重试。" }
        finally { busy=false }
    }
    fun remove(mid: Long) { items=items?.filterNot { it.mid==mid }; terms=terms-mid }
    fun reset() { keyword=""; items=null; terms=emptyMap(); busy=false; complete=false; error=null; restored=false }
    fun matches(): List<User> {
        val query=normalize(keyword).replace(Regex("\\s+"),"")
        val phonetic=phonetic(query)
        if (query.isEmpty()) return emptyList()
        return items.orEmpty().filter { user -> terms[user.mid]?.let { text ->
            text.name.contains(query) || text.pinyin.contains(phonetic) || text.pinyin.replace('v','u').contains(phonetic) || text.initials.contains(phonetic) ||
                (phonetic.length>=2 && phonetic.all { it.isLetter() && it.code<128 } && subsequence(phonetic,text.initials))
        }==true }
    }
    companion object {
        // Keep Latin name segments together while separating Chinese syllables on Android 8 and later.
        private fun pinyin(value: String)=buildString {
            value.forEach { c -> if (Pinyin.isChinese(c)) { append(' '); append(Pinyin.toPinyin(c)); append(' ') } else append(c) }
        }
        private fun normalize(value: String)=Normalizer.normalize(value.trim(),Normalizer.Form.NFKC).lowercase(Locale.ROOT)
        private fun phonetic(value: String)=Normalizer.normalize(normalize(value),Normalizer.Form.NFD).replace("u\u0308","v").replace(Regex("\\p{M}+"),"")
        private fun subsequence(query: String,value: String): Boolean { var at=0; for (c in value) if (at<query.length && c==query[at]) at++; return at==query.length }
        internal fun encode(uid: Long,users: List<User>): ByteArray = JSONObject().put("version",1).put("uid",uid).put("users",JSONArray(users.map { user ->
            JSONObject().put("mid",user.mid).put("name",user.name).put("face",user.avatar ?: JSONObject.NULL).put("sign",user.sign).put("fans",user.fans)
        })).toString().toByteArray(Charsets.UTF_8)
        internal fun decode(uid: Long,bytes: ByteArray): List<User> {
            val data=JSONObject(String(bytes,Charsets.UTF_8))
            if (data.optInt("version")!=1 || data.optLong("uid")!=uid || data.optJSONArray("users")==null) invalid("本地关注名单与当前账号不匹配。")
            val values=data.rows("users").map(User::parse)
            if (values.size!=data.getJSONArray("users").length() || values.any { it.mid<=0 || it.name.isBlank() } || values.map { it.mid }.distinct().size!=values.size) invalid("本地关注名单不完整。")
            return values
        }
    }
}
