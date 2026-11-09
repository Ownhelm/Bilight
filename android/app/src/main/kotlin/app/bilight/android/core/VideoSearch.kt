package app.bilight.android.core

import java.text.Normalizer

private val searchSeparators = Regex("[\\s\\p{Z}]+")

enum class VideoSearchOrder(val parameter: String, val label: String) {
    RELEVANCE("totalrank", "综合"),
    LATEST("pubdate", "最新"),
    MOST_PLAYED("click", "播放多")
}

internal fun List<Video>.matchingSearchTitles(keyword: String): List<Video> {
    val terms = Normalizer.normalize(keyword, Normalizer.Form.NFKC).split(searchSeparators).filter { it.isNotEmpty() }
    return filter { video ->
        val title = Normalizer.normalize(video.title, Normalizer.Form.NFKC)
        terms.all { title.contains(it, ignoreCase = true) }
    }
}
