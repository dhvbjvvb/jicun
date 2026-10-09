package com.videofix.jicun

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * B 站 CDN 的请求头约定:两端共用的一份规格在 tool/bilibili_headers.json。
 *
 * 为什么要有这个文件:原生(NativeDownloader.kt 的 [isBilibiliHost] / [BILIBILI_UA] /
 * [BROWSER_UA] / [BILIBILI_REFERER])与 Dart(playback.dart 的 `_isBilibiliHost` /
 * `kBilibiliUserAgent` / `kBrowserUserAgent`)**各有各的实现**,而它们错了不会崩 ——
 * 只会 403,表现成「音频预览 (0) SOURCE ERROR」或者「下载地址已失效」,很容易被当成
 * 「这条地址本来就不行」。以前只有 Dart 侧有用例:改了原生这边的域名表或 UA,Dart
 * 那边照样全绿,漂了没人知道。
 *
 * 现在两端读同一份规格(Dart 侧在 test/playback_headers_test.dart),规格里的每一条
 * 两端都要满足;要加判据就加数据,不用两头各写一遍断言。
 */
class NativeDownloaderBilibiliHeadersTest {

    private val spec: JSONObject by lazy {
        // Gradle 的单测工作目录是 android/app(Gradle 自己定),所以从那儿往上两级。
        // 多列几个候选:换个 Gradle 版本/换个跑法不至于直接红(和 DownloadLogicVectorsTest 一样)。
        val candidates = listOf(
            File("../../tool/bilibili_headers.json"),
            File("../tool/bilibili_headers.json"),
            File("tool/bilibili_headers.json"),
        )
        val file = candidates.firstOrNull { it.isFile }
        check(file != null) {
            "找不到 tool/bilibili_headers.json;试过:" + candidates.joinToString { it.absolutePath }
        }
        JSONObject(file.readText())
    }

    private fun hosts(key: String): List<String> {
        val array: JSONArray = spec.getJSONArray(key)
        check(array.length() > 0) { "$key 是空的(规格文件被改坏了?)" }
        return (0 until array.length()).map { array.getString(it) }
    }

    @Test
    fun `两个 UA 与 Referer 必须和共用规格逐字一致`() {
        assertEquals(
            "B 站那份 UA 与规格里的 bilibiliUserAgent 不一致",
            spec.getString("bilibiliUserAgent"),
            BILIBILI_UA,
        )
        assertEquals(
            "浏览器那份 UA 与规格里的 browserUserAgent 不一致",
            spec.getString("browserUserAgent"),
            BROWSER_UA,
        )
        assertEquals("Referer 与规格里的 referer 不一致", spec.getString("referer"), BILIBILI_REFERER)
    }

    @Test
    fun `规格里认的主机,原生这边都要认`() {
        for (host in hosts("biliHosts")) {
            assertTrue(
                "$host 在规格里算 B 站 CDN,原生这边不认 —— 会退回默认那份 Dalvik UA、还不带 Referer",
                isBilibiliHost(host),
            )
        }
    }

    @Test
    fun `规格里不认的主机,原生这边一个都不许认`() {
        for (host in hosts("notBiliHosts")) {
            assertFalse(
                "$host 不是 B 站 CDN:替别人家的域名加 Referer 正是这张表要避免的事",
                isBilibiliHost(host),
            )
        }
    }
}
