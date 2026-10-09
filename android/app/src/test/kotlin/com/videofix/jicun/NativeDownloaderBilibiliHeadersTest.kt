package com.videofix.jicun

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * B 站 CDN 的请求头约定:原生下载器(this file 的 [isBilibiliHost] / [BILIBILI_UA] /
 * [BROWSER_UA] / [BILIBILI_REFERER])与 Dart 侧(playback.dart 的 `_isBilibiliHost` /
 * `kBilibiliUserAgent` / `kBrowserUserAgent`)**各有一份实现**,两边必须是同一张表、
 * 同一个字符串。
 *
 * 为什么要有这个文件:这两份东西错了**不会崩** —— 只会 403,表现是「音频预览 (0)
 * SOURCE ERROR」或者「下载地址已失效」,而这类症状很容易被当成「这条地址本来就不行」。
 * 之前只有 Dart 侧的用例,原生这边没有任何东西盯着:改了 Kotlin 的域名表或 UA,Dart
 * 侧的用例照样全绿,漂了也没人知道。所以这里锁两件事:
 *   1. 域名判据的行为(自家域名 + `upos-*.akamaized.net` 认,别家的 Akamai 不碰);
 *   2. 两个 UA、Referer、域名后缀表**逐字**等于 Dart 侧那份(直接读 Dart 源文件比对)。
 */
class NativeDownloaderBilibiliHeadersTest {

    private val playbackDart: String by lazy {
        // Gradle 的单测工作目录是 android/app(Gradle 自己定),所以从那儿往上两级。
        // 多列几个候选:换个 Gradle 版本/换个跑法不至于直接红(和 DownloadLogicVectorsTest 一样)。
        val candidates = listOf(
            File("../../lib/ui/playback.dart"),
            File("../lib/ui/playback.dart"),
            File("lib/ui/playback.dart"),
        )
        val file = candidates.firstOrNull { it.isFile }
        check(file != null) {
            "找不到 lib/ui/playback.dart;试过:" + candidates.joinToString { it.absolutePath }
        }
        file.readText()
    }

    /** 取出 Dart 里 `const String <name> = '...' '...';` 的字面量拼起来的值。 */
    private fun dartString(name: String): String {
        val start = playbackDart.indexOf("const String $name")
        check(start >= 0) { "lib/ui/playback.dart 里找不到 $name" }
        // 认 `';` 收尾,不能找第一个 `;` —— UA 里本来就有分号("Windows NT 10.0; Win64")。
        val quote = playbackDart.indexOf("';", start)
        check(quote > start) { "$name 的声明没有以 '...'; 收尾" }
        val literals = Regex("'([^']*)'")
            .findAll(playbackDart.substring(start, quote + 1))
            .map { it.groupValues[1] }
            .toList()
        check(literals.isNotEmpty()) { "$name 里一个字符串字面量都没找到" }
        return literals.joinToString("")
    }

    /** Dart 里那个 B 站域名后缀名单(playback.dart 的 `_bilibiliHostSuffixes`)。 */
    private fun dartBilibiliSuffixes(): List<String> {
        val start = playbackDart.indexOf("const List<String> _bilibiliHostSuffixes")
        check(start >= 0) { "lib/ui/playback.dart 里找不到 _bilibiliHostSuffixes" }
        val end = playbackDart.indexOf("];", start)
        check(end > start) { "_bilibiliHostSuffixes 没有以 ]; 收尾" }
        return Regex("'([^']*)'")
            .findAll(playbackDart.substring(start, end))
            .map { it.groupValues[1] }
            .toList()
    }

    @Test
    fun `B 站镜像域名判据,自家域名和 upos- 镜像都认,别家的 Akamai 不碰`() {
        // 实测撞到过的那两条(见 NativeDownloader.kt 的注释):同一个视频,服务端一次给
        // 自家 CDN、一次给 Akamai 镜像。后者后缀里没有任何「B 站」字样,漏判就退回原生
        // 默认那份 Dalvik UA、还不带 Referer —— 直接 403。
        assertTrue(isBilibiliHost("upos-sz-mirrorcosov.bilivideo.com"))
        assertTrue(isBilibiliHost("upos-hz-mirrorakam.akamaized.net"))
        assertTrue(isBilibiliHost("upos-x.bilivideo.cn"))
        assertTrue(isBilibiliHost("www.bilibili.com"))
        assertTrue(isBilibiliHost("api.bilibili.com"))
        // Akamai 是公共 CDN:不带 upos- 前缀的一个都不许碰,替别人家的东西加 Referer 是越界。
        assertFalse(isBilibiliHost("mirror.akamaized.net"))
        assertFalse(isBilibiliHost("upos-x.akamaized.net.example.com"))
        assertFalse(isBilibiliHost("akamaized.net"))
        assertFalse(isBilibiliHost("douyinstatic.com"))
        assertFalse(isBilibiliHost(""))
    }

    @Test
    fun `两份 UA 和 Referer 必须和 Dart 侧逐字一致`() {
        assertEquals("B 站那份 UA 与 playback.dart 的 kBilibiliUserAgent 不一致", dartString("kBilibiliUserAgent"), BILIBILI_UA)
        assertEquals("浏览器那份 UA 与 playback.dart 的 kBrowserUserAgent 不一致", dartString("kBrowserUserAgent"), BROWSER_UA)
        assertTrue(
            "Referer 与 playback.dart 里那份不一致",
            playbackDart.contains("'$BILIBILI_REFERER'"),
        )
    }

    @Test
    fun `域名表两边一致,Dart 名单里的每个后缀原生这边都认,反向也不许多`() {
        val suffixes = dartBilibiliSuffixes()
        assertTrue("Dart 侧一个后缀都没解析出来(playback.dart 改结构了?)", suffixes.isNotEmpty())
        for (suffix in suffixes) {
            assertTrue(
                "Dart 认 $suffix,原生这边不认 —— 同一条地址会一个头都不发",
                isBilibiliHost("upos-x.$suffix"),
            )
        }
        // 反向:原生认的自家域名也必须都在 Dart 名单里,免得两边各加各的。
        for (suffix in listOf("bilivideo.com", "bilivideo.cn", "bilibili.com")) {
            assertTrue(
                "原生认 $suffix,但 playback.dart 的后缀名单里没有",
                suffixes.contains(suffix),
            )
        }
    }

    @Test
    fun `upos- 前缀那条规则 Dart 侧也写着`() {
        // 镜像规则的形状(前缀 + 后缀两段判据)如果只在一边存在,另一边就会整块漏判。
        assertTrue(playbackDart.contains("startsWith('upos-')"))
        assertTrue(playbackDart.contains("endsWith('akamaized.net')"))
    }
}
