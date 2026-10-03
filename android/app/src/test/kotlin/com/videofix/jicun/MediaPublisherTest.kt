package com.videofix.jicun

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 落盘那套**规矩**的用例(接缝见 PublishSink.kt)。
 *
 * 这几条盯的是最贵的一类错:错了不会崩,只会安静地丢一个文件、或者往相册里留半个。
 * 真正碰 Android API 的两小段(MediaStore / SAF)不在覆盖范围内 —— 那要真机才验得了,
 * 这里测的是"搬的规矩"。
 */
class MediaPublisherTest {

    /** 一个假的落盘目的地:记下写了什么、谁被调用过,并且可以按需在写入中途炸。 */
    private class FakeSink(
        private val visible: Boolean = true,
        /** 第几次 write 调用抛异常(从 1 起数);-1 = 不抛。 */
        private val failOnWriteCall: Int = -1,
    ) {
        val written = ByteArrayOutputStream()
        var removed = false
        var visibleAsked = false
        private var writeCalls = 0

        fun sink() = PublishSink(
            name = "测试.mp4",
            open = {
                object : SinkWriter {
                    override fun write(buffer: ByteBuffer): Int {
                        writeCalls++
                        if (writeCalls == failOnWriteCall) {
                            throw IOException("模拟写入中断(第 $writeCalls 块)")
                        }
                        val length = buffer.remaining()
                        val chunk = ByteArray(length)
                        buffer.get(chunk)
                        written.write(chunk)
                        return length
                    }

                    override fun close() {}
                }
            },
            makeVisible = {
                visibleAsked = true
                visible
            },
            remove = { removed = true },
        )
    }

    /** 造一份源文件,返回 (临时目录, 文件)。用完记得把目录删掉。 */
    private fun sourceOf(bytes: Int): Pair<File, File> {
        val dir = File(System.getProperty("java.io.tmpdir"), "jicun-publish-${System.nanoTime()}")
        dir.mkdirs()
        val file = File(dir, "x.bin")
        file.writeBytes(ByteArray(bytes) { (it % 251).toByte() })
        return dir to file
    }

    @Test
    fun `成功 整条搬过去、让它可见、删掉源`() {
        val (dir, source) = sourceOf(4096)
        val expected = source.readBytes()
        val fake = FakeSink()

        publishInto(source, fake.sink(), null)

        assertArrayEquals("字节要一模一样", expected, fake.written.toByteArray())
        assertTrue("要让它对外可见", fake.visibleAsked)
        assertFalse("成功必须把缓存里那份删掉", source.exists())
        dir.deleteRecursively()
    }

    @Test
    fun `可见性没生效就当失败 撤掉记录、源不删`() {
        val (dir, source) = sourceOf(1024)
        val fake = FakeSink(visible = false)

        val thrown = try {
            publishInto(source, fake.sink(), null)
            null
        } catch (e: IllegalStateException) {
            e
        }

        assertTrue("要把那条记录撤掉,否则相册里留一个打不开的壳", fake.removed)
        assertTrue("源不能删:调用方还要拿它报失败", source.exists())
        assertTrue(
            "文案不能改",
            thrown?.message?.contains("媒体库没能把这条标成可见") == true,
        )
        dir.deleteRecursively()
    }

    @Test
    fun `写到一半失败 撤掉记录、源不删、异常原样上抛`() {
        // 源要大于一块(1MB),否则一次 write 就写完了,测不到"搬一半断掉"
        val (dir, source) = sourceOf(3 * 1024 * 1024)
        val fake = FakeSink(failOnWriteCall = 2)

        val thrown = try {
            publishInto(source, fake.sink(), null)
            null
        } catch (e: IOException) {
            e
        }

        assertTrue("异常要原样上抛", thrown != null)
        assertTrue("要把那条记录撤掉", fake.removed)
        assertTrue("源不能删", source.exists())
        assertFalse("还没搬完,不该走到可见性那一步", fake.visibleAsked)
        dir.deleteRecursively()
    }

    @Test
    fun `进度收尾报满一次、数值等于真实字节`() {
        val size = 3 * 1024 * 1024
        val (dir, source) = sourceOf(size)
        val seen = mutableListOf<Pair<Long, Long>>()

        publishInto(source, FakeSink().sink()) { copied, total ->
            seen += copied to total
        }

        assertEquals("收尾那次是最后一条", size.toLong(), seen.last().first)
        assertEquals(size.toLong(), seen.last().second)
        assertEquals("不能超过整条", size.toLong(), seen.maxOf { it.first })
        dir.deleteRecursively()
    }
}
