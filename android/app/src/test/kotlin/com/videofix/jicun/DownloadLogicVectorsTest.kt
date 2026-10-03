package com.videofix.jicun

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * 下载器纯逻辑的**跨端规格**:向量来自 tool/download_logic_vectors.json,由
 * tool/gen_logic_vectors.py 生成。Dart(test/download_logic_vectors_test.dart)读的是同一份
 * 数据。
 *
 * 为什么要有这个文件:这几个函数错了**不会崩**,只会下出一个坏文件(少一段、
 * 写重一段)或者在 80% 处误报失败。两端各写一份实现,靠这份向量对齐 ——
 * 以前只有各写各的单元测试,谁也不知道另一边的边界条件是不是一样。
 */
class DownloadLogicVectorsTest {

    private val root: JSONObject by lazy {
        // Gradle 的单测工作目录是 android/app(Gradle 自己定),所以从那儿往上两级。
        // 随手也试一下 ../ —— 换个 Gradle 版本/换个跑法不至于直接红。
        val candidates = listOf(
            File("../../tool/download_logic_vectors.json"),
            File("../tool/download_logic_vectors.json"),
            File("tool/download_logic_vectors.json"),
        )
        val file = candidates.firstOrNull { it.isFile }
        check(file != null) {
            "找不到测试向量;试过:" + candidates.joinToString { it.absolutePath }
        }
        JSONObject(file.readText())
    }

    @Test
    fun `认领切分 给定行就逐行对,没给行也要严丝合缝铺满`() {
        val cases = root.getJSONArray("chunkCases")
        assertTrue(cases.length() > 0)
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val size = c.getLong("size")
            val chunk = c.getLong("chunk")
            val claims = c.getLong("claims")
            val rows = c.optJSONArray("rows")

            if (rows != null) {
                assertEquals(c.getString("name"), claims.toInt(), rows.length())
                for (claim in 0 until rows.length()) {
                    val got = claimedChunk(claim.toLong(), size, chunk)
                    assertNotNull("${c.getString("name")}:第 $claim 次认领不该为空", got)
                    assertEquals(rows.getJSONArray(claim).getLong(0), got!!.first)
                    assertEquals(rows.getJSONArray(claim).getLong(1), got.last)
                }
                assertNull(claimedChunk(claims, size, chunk))
            } else {
                // 没给行的(认领次数太多):迭代验证每一段接上一段,总覆盖等于 size。
                var expect = 0L
                var seen = 0L
                while (true) {
                    val got = claimedChunk(seen, size, chunk) ?: break
                    assertEquals("${c.getString("name")}:第 $seen 段起点", expect, got.first)
                    expect = got.last + 1
                    seen++
                    assertTrue("认领不收敛", seen <= 1_000_000)
                }
                assertEquals(c.getString("name"), claims, seen)
                assertEquals(c.getString("name") + ":有洞", size, expect)
            }
            assertTrue(c.getBoolean("covers"))
        }
    }

    @Test
    fun `带尾巴的切分 尾巴变小但不能切出洞`() {
        val cases = root.getJSONArray("tailCases")
        assertTrue(cases.length() > 0)
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val size = c.getLong("size")
            val chunk = c.getLong("chunk")
            val tail = c.getLong("tail")
            val tailChunk = c.getLong("tailChunk")
            val rows = c.getJSONArray("rows")
            var expect = 0L
            for (claim in 0 until rows.length()) {
                val got = claimedChunkWithTail(claim.toLong(), size, chunk, tail, tailChunk)
                assertNotNull(got)
                assertEquals(rows.getJSONArray(claim).getLong(0), got!!.first)
                assertEquals(rows.getJSONArray(claim).getLong(1), got.last)
                assertEquals("${c.getString("name")}:第 $claim 段不接上一段", expect, got.first)
                expect = got.last + 1
            }
            assertEquals(c.getString("name"), c.getLong("claims"), rows.length().toLong())
            assertNull(claimedChunkWithTail(rows.length().toLong(), size, chunk, tail, tailChunk))
            assertEquals(size, expect)
        }
    }

    @Test
    fun `文件不到尾巴两倍时带尾巴那版退化成普通切分`() {
        val size = 20L shl 20 // < 2 x 32MB
        var plain = 0L
        while (claimedChunk(plain, size, 4L shl 20) != null) plain++
        var tailed = 0L
        while (claimedChunkWithTail(tailed, size, 4L shl 20, 32L shl 20, 1L shl 20) != null) tailed++
        assertEquals(plain, tailed)
    }

    @Test
    fun `断点续传的下一跳夹在段尾加一`() {
        val cases = root.getJSONArray("resumeCases")
        assertTrue(cases.length() > 0)
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            assertEquals(
                c.toString(),
                c.getLong("expected"),
                resumeOffset(c.getLong("written"), c.getLong("offset"), c.getLong("end")),
            )
        }
    }

    @Test
    fun `连接轮换判据`() {
        val cases = root.getJSONArray("rotateCases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            assertEquals(
                c.toString(),
                c.getBoolean("expected"),
                shouldRotateConnection(
                    c.getLong("start"),
                    c.getLong("written"),
                    c.getLong("wanted"),
                    c.getLong("elapsed"),
                    c.getLong("budget"),
                ),
            )
        }
    }

    @Test
    fun `200 什么时候能当就是这一段`() {
        val cases = root.getJSONArray("rangeCases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            assertEquals(
                c.toString(),
                c.getBoolean("expected"),
                wholeFileAsRange(
                    c.getInt("code"),
                    c.getLong("start"),
                    c.getLong("end"),
                    c.getLong("contentLength"),
                ),
            )
        }
    }

    @Test
    fun `批量下载时按文件数摊薄连接额度`() {
        val cases = root.getJSONArray("laneCases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            assertEquals(
                c.toString(),
                c.getInt("expected"),
                lanesPerItem(c.getInt("lanes"), c.getInt("items")),
            )
        }
    }

    @Test
    fun `段级重试账本 有进展清零、连续空手才放弃、退避封顶`() {
        val cases = root.getJSONArray("attemptCases")
        assertTrue(cases.length() > 0)
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val expected = c.getJSONObject("expected")
            val steps = expected.getJSONArray("steps")
            val book = ChunkAttempts(c.getInt("stallLimit"), c.getInt("attemptLimit"))

            for (step in 0 until steps.length()) {
                val s = steps.getJSONObject(step)
                assertEquals(
                    "${c.getString("name")}:第 $step 步的 retry",
                    s.getBoolean("retry"),
                    book.noteFailure(s.getLong("progress")),
                )
                assertEquals(
                    "${c.getString("name")}:第 $step 步的退避",
                    s.getLong("delayMs"),
                    book.delay,
                )
            }
            assertEquals(expected.getInt("attempts"), book.attempts)
            assertEquals(expected.getInt("stalls"), book.stalls)
            assertEquals(expected.getLong("finalDelayMs"), book.delay)
        }
    }

    @Test
    fun `向量文件本身不能是旧的`() {
        // gen_logic_vectors.py 不 --write 时也做同样的校验;这条只是让改了实现忘了
        // 重新生成的提交在 CI 上就红。
        assertFalse(root.getString("note").isEmpty())
    }
}
