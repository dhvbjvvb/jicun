package com.videofix.jicun

import java.io.IOException
import java.net.SocketException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeDownloaderTest {
    @Test
    fun lanesCoverTheWholeFileWithoutGaps() {
        // 共享游标认领的段必须严丝合缝铺满整条文件 —— 曾经因为"每条 lane 只负责
        // 一个 4MB 区间"导致无论多大都只收到前 32MB。
        val size = 152_938_811L
        val chunk = 4L * 1024 * 1024
        val claims = (0L until 37L).mapNotNull { claimedChunk(it, size, chunk) }

        assertEquals(37, claims.size)
        assertEquals(0L, claims.first().first)
        assertEquals(size - 1, claims.last().last)
        claims.zipWithNext().forEach { (left, right) ->
            assertEquals(left.last + 1, right.first)
        }
        assertEquals(size, claims.sumOf { it.last - it.first + 1 })
        // 认领次数用完了:第 38 次该收工(返回 null)
        assertEquals(null, claimedChunk(37, size, chunk))
    }

    @Test
    fun `尾巴小段也不留缝不重叠`() {
        // 实测那份 153MB 的文件:大段 4MB + 末尾 32MB 按 1MB 切
        val size = 152_938_811L
        val chunk = 4L * 1024 * 1024
        val tail = 32L * 1024 * 1024
        val tailChunk = 1L * 1024 * 1024
        val claims = (0L until 200L).mapNotNull {
            claimedChunkWithTail(it, size, chunk, tail, tailChunk)
        }

        assertEquals(0L, claims.first().first)
        assertEquals(size - 1, claims.last().last)
        claims.zipWithNext().forEach { (left, right) ->
            assertEquals(left.last + 1, right.first)
        }
        assertEquals(size, claims.sumOf { it.last - it.first + 1 })
        // 尾巴上的段确实变小了:最后 32 段每段不超过 1MB
        claims.takeLast(32).forEach {
            assertTrue(it.last - it.first + 1 <= tailChunk)
        }
        // 大段仍是大段:第一段还是 4MB
        assertEquals(chunk, claims.first().last - claims.first().first + 1)
        // 认领到段数之外返回 null
        assertEquals(null, claimedChunkWithTail(claims.size.toLong(), size, chunk, tail, tailChunk))
    }

    @Test
    fun `文件不够大就不切尾巴`() {
        // 10MB 的文件:整条按 4MB 一大段走,不因为"尾巴"多出一串 1MB 的握手
        val size = 10L * 1024 * 1024
        val claims = (0L until 10L).mapNotNull {
            claimedChunkWithTail(
                it,
                size,
                4L * 1024 * 1024,
                32L * 1024 * 1024,
                1L * 1024 * 1024,
            )
        }
        assertEquals(3, claims.size)
        assertEquals(
            listOf(4L, 4L, 2L).map { it * 1024 * 1024 },
            claims.map { it.last - it.first + 1 },
        )
    }

    @Test
    fun `连接被重置后重试同一段并成功`() {
        var calls = 0
        val slept = mutableListOf<Long>()
        val retried = mutableListOf<Int>()

        val result = retrying(
            attempts = 3,
            delays = longArrayOf(300, 900),
            sleep = { slept += it },
            onRetry = { n, _, _ -> retried += n },
        ) {
            calls++
            if (calls < 3) throw SocketException("Connection reset") else 42
        }

        assertEquals(42, result)
        assertEquals(3, calls)
        assertEquals(listOf(300L, 900L), slept)
        assertEquals(listOf(1, 2), retried)
    }

    @Test
    fun `全部失败时抛最后一次的异常`() {
        var calls = 0
        val thrown = try {
            retrying<Int>(attempts = 3, delays = longArrayOf(0, 0), sleep = {}) {
                calls++
                throw IOException("第 $calls 次")
            }
            null
        } catch (e: IOException) {
            e
        }

        assertEquals(3, calls)
        assertEquals("第 3 次", thrown?.message)
    }

    @Test
    fun `取消不重试`() {
        var calls = 0
        val thrown = try {
            retrying<Int>(
                attempts = 3,
                delays = longArrayOf(0, 0),
                fatal = { it is InterruptedException },
                sleep = {},
            ) {
                calls++
                throw InterruptedException()
            }
            null
        } catch (e: InterruptedException) {
            e
        }

        assertTrue(thrown is InterruptedException)
        assertEquals(1, calls)
    }

    @Test
    fun `重试次数用完之前不睡最后一次`() {
        val slept = mutableListOf<Long>()
        // 只给一格延迟,第 2、3 次重试都用它 —— 索引越界不该发生
        try {
            retrying<Int>(attempts = 3, delays = longArrayOf(5), sleep = { slept += it }) {
                throw IOException("down")
            }
        } catch (_: IOException) {
        }
        assertEquals(listOf(5L, 5L), slept)
    }

    @Test
    fun `服务端错误码不重试`() {
        var calls = 0
        try {
            retrying<Int>(
                attempts = 3,
                delays = longArrayOf(0, 0),
                fatal = { it is HttpStatusError },
                sleep = {},
            ) {
                calls++
                throw HttpStatusError("HTTP 403")
            }
        } catch (_: HttpStatusError) {
        }
        assertEquals(1, calls)
    }

    @Test
    fun `断点续传从收下的字节之后接着要`() {
        // 段 0..4194303,收了 1MB 就断了 → 下一次从 1048576 起
        assertEquals(1_048_576L, resumeOffset(1_048_576, 0, 4_194_303))
        // 已经收了一半,又断了 100 字节 → 续传位置继续往前推
        assertEquals(2_048_676L, resumeOffset(100, 2_048_576, 4_194_303))
    }

    @Test
    fun `收满整段的下一跳是段尾加一`() {
        // 刚收完就被 RST:再要一次会发出 bytes=X-(X-1) 这种非法区间
        assertEquals(4_194_304L, resumeOffset(4_194_304, 0, 4_194_303))
        // 报出来的字节数比这一段剩下的还多(不该发生):同样夹在段尾 + 1
        assertEquals(4_194_304L, resumeOffset(99_999_999, 0, 4_194_303))
    }

    @Test
    fun `有进展就一直重试,断多少次都不判失败`() {
        // B 站那条实测:每几 MB 断一次,但每次都收到了字节 —— 固定 3 次会在长文件
        // 后半段必然失败,按"有没有进展"算就不会(35 次都还在往前收)。
        val tries = ChunkAttempts(stallLimit = 4, attemptLimit = 40)
        repeat(35) { assertTrue(tries.noteFailure(1_000_000)) }
        assertEquals(0, tries.stalls)
        assertEquals(200L, tries.delay)
    }

    @Test
    fun `连续收不到字节才放弃`() {
        val tries = ChunkAttempts(stallLimit = 4, attemptLimit = 40)
        assertTrue(tries.noteFailure(0))
        assertTrue(tries.noteFailure(0))
        assertTrue(tries.noteFailure(0))
        assertFalse(tries.noteFailure(0))
        assertEquals(4, tries.stalls)
        assertEquals(4, tries.attempts)
    }

    @Test
    fun `等待时间随连续失败翻倍并封顶`() {
        val tries = ChunkAttempts(stallLimit = 9, attemptLimit = 40)
        tries.noteFailure(0)
        assertEquals(200L, tries.delay)
        repeat(8) { tries.noteFailure(0) }
        assertEquals(2000L, tries.delay)
    }

    @Test
    fun `收到字节就把连续失败清零`() {
        val tries = ChunkAttempts(stallLimit = 4, attemptLimit = 40)
        repeat(3) { tries.noteFailure(0) }
        assertEquals(3, tries.stalls)
        assertTrue(tries.noteFailure(1024))
        assertEquals(0, tries.stalls)
        assertEquals(4, tries.attempts)
    }

    @Test
    fun `慢连接到点就换,收完就不换`() {
        val budget = 10_000L
        // 用了 10 秒只收了 1MB / 4MB:换
        assertTrue(shouldRotateConnection(0, 1_048_576, 4_194_304, 10_000, budget))
        // 还没到点:先让它收
        assertFalse(shouldRotateConnection(0, 1_048_576, 4_194_304, 9_999, budget))
        // 这一段的剩余部分已经收完(只是还没走到 EOF):不换
        assertFalse(shouldRotateConnection(0, 4_194_304, 4_194_304, 60_000, budget))
        // 整条顺序写(start < 0)没有断点可续,换连接等于从 0 重来:不换
        assertFalse(shouldRotateConnection(-1, 1_048_576, -1, 600_000, budget))
    }

    @Test
    fun `单条文件不吃摊薄`() {
        assertEquals(32, lanesPerItem(32, 1))
        assertEquals(64, lanesPerItem(64, 1))
    }

    @Test
    fun `批量下大文件时按文件数摊连接`() {
        // 4 个视频各开 32 条 = 128 条连接,那是去撞 CDN 并发上限的
        assertEquals(8, lanesPerItem(32, 4))
        assertEquals(10, lanesPerItem(32, 3))
        // 文件比额度还多:每个至少留 1 条
        assertEquals(1, lanesPerItem(32, 40))
    }

    @Test
    fun `尝试次数硬上限兜住每次只前进一丁点`() {
        val tries = ChunkAttempts(stallLimit = 4, attemptLimit = 5)
        repeat(4) { assertTrue(tries.noteFailure(1)) }
        assertFalse(tries.noteFailure(1))
    }
}
